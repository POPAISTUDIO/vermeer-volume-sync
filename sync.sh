#!/bin/bash
set -o pipefail

echo "=== Vermeer Volume Sync ==="
echo "Starting sync at $(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Validate required environment variables
if [ -z "$S3_ACCESS_KEY" ] || [ -z "$S3_SECRET_KEY" ]; then
    echo "ERROR: S3_ACCESS_KEY and S3_SECRET_KEY are required"
    exit 1
fi

if [ -z "$SOURCE_ENDPOINT" ] || [ -z "$SOURCE_VOLUME_ID" ]; then
    echo "ERROR: SOURCE_ENDPOINT and SOURCE_VOLUME_ID are required"
    exit 1
fi

# Extract region from endpoint URL (e.g., https://s3api-eu-ro-1.runpod.io -> eu-ro-1)
REGION=$(echo "$SOURCE_ENDPOINT" | sed -E 's|https://s3api-([^.]+)\.runpod\.io.*|\1|')
if [ -z "$REGION" ] || [ "$REGION" = "$SOURCE_ENDPOINT" ]; then
    echo "WARNING: Could not extract region from endpoint, using default"
    REGION="us-east-1"
fi
echo "Detected region: $REGION"

# Configure AWS CLI
export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
export AWS_DEFAULT_REGION="$REGION"

# Target directory (RunPod mounts volumes at /workspace)
TARGET_DIR="${TARGET_DIR:-/workspace}"

echo "Source: s3://${SOURCE_VOLUME_ID}/ (endpoint: ${SOURCE_ENDPOINT})"
echo "Target: ${TARGET_DIR}"

# Exclusions: skip machine-specific / regenerable directories
SYNC_EXCLUDES=(
    --exclude ".venv/*"
    --exclude "__pycache__/*"
    --exclude "*.pyc"
    --exclude "node_modules/*"
    --exclude ".cache/*"
    --exclude ".tmp/*"
)
echo "Excluding: .venv, __pycache__, *.pyc, node_modules, .cache, .tmp"

# ── Progress reporting helper ──
report_progress() {
    local phase="$1"
    local synced="$2"
    local total="$3"

    if [ -z "$PROGRESS_CALLBACK_URL" ] || [ -z "$JOB_ID" ]; then
        return
    fi

    local payload
    payload=$(jq -n \
        --arg job_id "$JOB_ID" \
        --arg phase "$phase" \
        --argjson synced "${synced:-0}" \
        --argjson total "${total:-0}" \
        '{job_id: $job_id, phase: $phase, files_synced: $synced, files_total: $total}')

    curl -s -X POST "$PROGRESS_CALLBACK_URL" \
        -H "Content-Type: application/json" \
        -d "$payload" > /dev/null 2>&1 || true
}

# ── Start sync immediately + fast parallel S3 API discovery ──
echo ""
echo "=== Starting S3 Sync ==="
SYNC_START=$(date +%s)

# Progress counter file (written by awk during sync, read by reporter)
PROGRESS_FILE="/tmp/sync_progress"
echo "0" > "$PROGRESS_FILE"

# Total count file (written by background S3 API discovery, read by reporter)
FILES_TOTAL_FILE="/tmp/files_total"
echo "0" > "$FILES_TOTAL_FILE"

# ── Fast parallel discovery using S3 API pagination ──
# Uses list-objects-v2 (1000 objects/page via API) instead of `aws s3 ls`
# which streams all metadata as text. This is 10-50x faster.
# Total is updated PROGRESSIVELY as each page comes in.
(
    TOTAL=0
    TOKEN=""
    PAGE=0
    while true; do
        CMD_ARGS=(s3api list-objects-v2
            --bucket "$SOURCE_VOLUME_ID"
            --endpoint-url "$SOURCE_ENDPOINT"
            --output json)
        [ -n "$TOKEN" ] && CMD_ARGS+=(--continuation-token "$TOKEN")

        RESULT=$(aws "${CMD_ARGS[@]}" 2>/dev/null) || break
        COUNT=$(echo "$RESULT" | jq '.KeyCount // 0')
        TOTAL=$((TOTAL + COUNT))
        PAGE=$((PAGE + 1))

        # Progressive update: write current total so reporter can use it immediately
        echo "$TOTAL" > "$FILES_TOTAL_FILE"

        # Check if there are more pages
        IS_TRUNCATED=$(echo "$RESULT" | jq -r '.IsTruncated // false')
        if [ "$IS_TRUNCATED" = "true" ]; then
            TOKEN=$(echo "$RESULT" | jq -r '.NextContinuationToken // empty')
            [ -z "$TOKEN" ] && break
        else
            break
        fi
    done
    echo "S3 API discovery: ${TOTAL} objects (${PAGE} pages)" >&2
) &
DISCOVERY_PID=$!
echo "Fast S3 API discovery started in background (list-objects-v2)"

# Report initial state
report_progress "syncing" 0 0

# ── Run sync in background, writing directly to log file ──
# IMPORTANT: No pipes! aws s3 sync (Python) full-buffers when piped,
# causing zero output until buffer fills. Writing to a file avoids this.
aws s3 sync "s3://${SOURCE_VOLUME_ID}/" "${TARGET_DIR}/" \
    --endpoint-url "$SOURCE_ENDPOINT" \
    --region "$REGION" \
    "${SYNC_EXCLUDES[@]}" \
    --no-progress \
    > /tmp/sync.log 2>&1 &
SYNC_PID=$!
echo "Sync started (PID: $SYNC_PID)"

# ── Monitor loop: count downloads + report progress every 5s ──
PREV_COUNT=0
while kill -0 "$SYNC_PID" 2>/dev/null; do
    sleep 5
    COUNT=$(grep -c "download:" /tmp/sync.log 2>/dev/null || true)
    COUNT=${COUNT:-0}
    TOTAL=$(cat "$FILES_TOTAL_FILE" 2>/dev/null || true)
    TOTAL=${TOTAL:-0}

    if [ "$COUNT" -ne "$PREV_COUNT" ]; then
        if [ "$TOTAL" -gt 0 ]; then
            PCT=$((COUNT * 100 / TOTAL))
            echo "[progress] ${COUNT} files synced / ~${TOTAL} in bucket (${PCT}%)"
        else
            echo "[progress] ${COUNT} files synced"
        fi
        echo "$COUNT" > "$PROGRESS_FILE"
        PREV_COUNT=$COUNT
    fi

    report_progress "syncing" "$COUNT" "$TOTAL"
done

wait "$SYNC_PID"
SYNC_STATUS=$?

# Print sync log for container debugging
echo ""
echo "=== Sync Log (last 50 lines) ==="
tail -n 50 /tmp/sync.log 2>/dev/null

# ── Cleanup background discovery ──
if kill -0 "$DISCOVERY_PID" 2>/dev/null; then
    kill "$DISCOVERY_PID" 2>/dev/null
    wait "$DISCOVERY_PID" 2>/dev/null
fi

# Fallback: check for fatal errors in log
if [ $SYNC_STATUS -eq 0 ] && grep -q "fatal error" /tmp/sync.log; then
    echo "WARNING: Detected fatal error in log despite exit code 0"
    SYNC_STATUS=1
fi

SYNC_END=$(date +%s)
SYNC_DURATION=$((SYNC_END - SYNC_START))
FILES_SYNCED=$(cat "$PROGRESS_FILE" 2>/dev/null || true)
FILES_SYNCED=${FILES_SYNCED:-0}
FILES_TOTAL=$(cat "$FILES_TOTAL_FILE" 2>/dev/null || true)
FILES_TOTAL=${FILES_TOTAL:-0}

echo ""
echo "=== Sync Complete ==="
echo "Duration: ${SYNC_DURATION}s"
echo "Files downloaded: ${FILES_SYNCED}"
echo "Objects in bucket: ~${FILES_TOTAL}"
echo "Exit code: ${SYNC_STATUS}"

# Determine final status
if [ $SYNC_STATUS -eq 0 ]; then
    FINAL_STATUS="synced"
    echo "Status: SUCCESS"
    # Report 100%: use total from discovery if available, otherwise use synced count
    if [ "$FILES_TOTAL" -gt 0 ]; then
        report_progress "syncing" "$FILES_TOTAL" "$FILES_TOTAL"
    else
        report_progress "syncing" "$FILES_SYNCED" "$FILES_SYNCED"
    fi
else
    FINAL_STATUS="failed"
    echo "Status: FAILED"
fi

# ── Send completion callback ──
if [ -n "$CALLBACK_URL" ]; then
    echo ""
    echo "=== Sending Callback ==="

    CALLBACK_PAYLOAD=$(jq -n \
        --arg job_id "$JOB_ID" \
        --arg status "$FINAL_STATUS" \
        --arg duration "$SYNC_DURATION" \
        --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{job_id: $job_id, status: $status, duration_seconds: ($duration | tonumber), completed_at: $timestamp}')

    echo "Payload: $CALLBACK_PAYLOAD"

    CALLBACK_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$CALLBACK_URL" \
        -H "Content-Type: application/json" \
        -d "$CALLBACK_PAYLOAD")

    HTTP_CODE=$(echo "$CALLBACK_RESPONSE" | tail -n1)
    RESPONSE_BODY=$(echo "$CALLBACK_RESPONSE" | head -n -1)

    echo "Callback response: HTTP $HTTP_CODE"

    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
        echo "Callback sent successfully"
    else
        echo "WARNING: Callback failed with HTTP $HTTP_CODE"
        echo "Response: $RESPONSE_BODY"
    fi
fi

echo ""
echo "=== Done ==="
exit $SYNC_STATUS

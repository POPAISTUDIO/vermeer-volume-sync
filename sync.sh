#!/bin/bash
set -o pipefail

echo "=== Vermeer Volume Sync ==="
echo "Starting sync at $(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# ── Validate environment ──
if [ -z "$S3_ACCESS_KEY" ] || [ -z "$S3_SECRET_KEY" ]; then
    echo "ERROR: S3_ACCESS_KEY and S3_SECRET_KEY are required"
    exit 1
fi
if [ -z "$SOURCE_ENDPOINT" ] || [ -z "$SOURCE_VOLUME_ID" ]; then
    echo "ERROR: SOURCE_ENDPOINT and SOURCE_VOLUME_ID are required"
    exit 1
fi

REGION=$(echo "$SOURCE_ENDPOINT" | sed -E 's|https://s3api-([^.]+)\.runpod\.io.*|\1|')
if [ -z "$REGION" ] || [ "$REGION" = "$SOURCE_ENDPOINT" ]; then
    REGION="us-east-1"
fi
echo "Region: $REGION"

export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
export AWS_DEFAULT_REGION="$REGION"

TARGET_DIR="${TARGET_DIR:-/workspace}"
echo "Source: s3://${SOURCE_VOLUME_ID}/"
echo "Target: ${TARGET_DIR}"

SYNC_EXCLUDES=(
    --exclude ".venv/*"
    --exclude "__pycache__/*"
    --exclude "*.pyc"
    --exclude "node_modules/*"
    --exclude ".cache/*"
    --exclude ".tmp/*"
)

# ── Progress callback (non-blocking, never fails the sync) ──
report_progress() {
    local phase="$1" synced="$2" total="$3"
    [ -z "$PROGRESS_CALLBACK_URL" ] || [ -z "$JOB_ID" ] && return
    curl -s -X POST "$PROGRESS_CALLBACK_URL" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg job_id "$JOB_ID" \
            --arg phase "$phase" \
            --argjson synced "${synced:-0}" \
            --argjson total "${total:-0}" \
            '{job_id: $job_id, phase: $phase, files_synced: $synced, files_total: $total}')" \
        > /dev/null 2>&1 || true
}

# ── Count files on disk (the source of truth for progress) ──
count_local_files() {
    find "$TARGET_DIR" -type f 2>/dev/null | wc -l | tr -d ' '
}

echo ""
echo "=== Starting ==="
SYNC_START=$(date +%s)

# Snapshot initial file count before sync
INITIAL_FILES=$(count_local_files)
echo "Files already on disk: $INITIAL_FILES"

# ── Background: fast S3 object count via API pagination ──
FILES_TOTAL_FILE="/tmp/files_total"
echo "0" > "$FILES_TOTAL_FILE"
(
    TOTAL=0
    TOKEN=""
    while true; do
        CMD=(aws s3api list-objects-v2 --bucket "$SOURCE_VOLUME_ID" --endpoint-url "$SOURCE_ENDPOINT" --output json)
        [ -n "$TOKEN" ] && CMD+=(--continuation-token "$TOKEN")
        RESULT=$("${CMD[@]}" 2>/dev/null) || break
        TOTAL=$((TOTAL + $(echo "$RESULT" | jq '.KeyCount // 0')))
        echo "$TOTAL" > "$FILES_TOTAL_FILE"
        IS_TRUNCATED=$(echo "$RESULT" | jq -r '.IsTruncated // false')
        [ "$IS_TRUNCATED" = "true" ] || break
        TOKEN=$(echo "$RESULT" | jq -r '.NextContinuationToken // empty')
        [ -z "$TOKEN" ] && break
    done
    echo "[discovery] $TOTAL objects in S3 bucket" >&2
) &
DISCOVERY_PID=$!

report_progress "syncing" 0 0

# ── Run sync silently in background ──
aws s3 sync "s3://${SOURCE_VOLUME_ID}/" "${TARGET_DIR}/" \
    --endpoint-url "$SOURCE_ENDPOINT" \
    --region "$REGION" \
    "${SYNC_EXCLUDES[@]}" \
    --only-show-errors \
    > /tmp/sync_errors.log 2>&1 &
SYNC_PID=$!
echo "Sync PID: $SYNC_PID"

# ── Monitor: count files on disk every 10s ──
# No dependency on aws CLI output. The filesystem is the source of truth.
while kill -0 "$SYNC_PID" 2>/dev/null; do
    sleep 10

    CURRENT_FILES=$(count_local_files)
    NEW_FILES=$((CURRENT_FILES - INITIAL_FILES))
    TOTAL=$(cat "$FILES_TOTAL_FILE" 2>/dev/null || true)
    TOTAL=${TOTAL:-0}

    if [ "$TOTAL" -gt 0 ]; then
        PCT=$((CURRENT_FILES * 100 / TOTAL))
        echo "[progress] ${CURRENT_FILES} files on disk / ~${TOTAL} in S3 (+${NEW_FILES} new, ${PCT}%)"
    else
        echo "[progress] ${CURRENT_FILES} files on disk (+${NEW_FILES} new)"
    fi

    report_progress "syncing" "$CURRENT_FILES" "$TOTAL"
done

wait "$SYNC_PID"
SYNC_STATUS=$?

# Cleanup discovery if still running
kill "$DISCOVERY_PID" 2>/dev/null; wait "$DISCOVERY_PID" 2>/dev/null

# Check for errors in sync log
if [ $SYNC_STATUS -eq 0 ] && grep -q "fatal error" /tmp/sync_errors.log 2>/dev/null; then
    SYNC_STATUS=1
fi
if [ -s /tmp/sync_errors.log ]; then
    echo ""
    echo "=== Sync Errors ==="
    cat /tmp/sync_errors.log
fi

# ── Results ──
SYNC_END=$(date +%s)
SYNC_DURATION=$((SYNC_END - SYNC_START))
FINAL_FILES=$(count_local_files)
TOTAL=$(cat "$FILES_TOTAL_FILE" 2>/dev/null || true)
TOTAL=${TOTAL:-0}

echo ""
echo "=== Sync Complete ==="
echo "Duration: ${SYNC_DURATION}s"
echo "Files on disk: ${FINAL_FILES} (was ${INITIAL_FILES}, +$((FINAL_FILES - INITIAL_FILES)) new)"
echo "Objects in S3: ~${TOTAL}"
echo "Exit code: ${SYNC_STATUS}"

if [ $SYNC_STATUS -eq 0 ]; then
    FINAL_STATUS="synced"
    echo "Status: SUCCESS"
    if [ "$TOTAL" -gt 0 ]; then
        report_progress "syncing" "$TOTAL" "$TOTAL"
    else
        report_progress "syncing" "$FINAL_FILES" "$FINAL_FILES"
    fi
else
    FINAL_STATUS="failed"
    echo "Status: FAILED"
fi

# ── Completion callback ──
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

    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
        echo "Callback: HTTP $HTTP_CODE OK"
    else
        echo "Callback: HTTP $HTTP_CODE FAILED"
        echo "$CALLBACK_RESPONSE" | head -n -1
    fi
fi

echo ""
echo "=== Done ==="
exit $SYNC_STATUS

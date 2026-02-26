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
# Format: https://s3api-{region}.runpod.io
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
# Posts progress to PROGRESS_CALLBACK_URL (non-blocking, never fails the sync)
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

# ── Phase 1: Discovery (dryrun with 30s timeout) ──
echo ""
echo "=== Discovery Phase (max 30s) ==="
report_progress "discovering" 0 0

DRYRUN_OUTPUT="/tmp/dryrun.txt"
FILES_TOTAL=0
DISCOVERY_TIMEOUT=30
DISCOVERY_SKIPPED=false

# Run dryrun in background with timeout
aws s3 sync "s3://${SOURCE_VOLUME_ID}/" "${TARGET_DIR}/" \
    --endpoint-url "$SOURCE_ENDPOINT" \
    --region "$REGION" \
    "${SYNC_EXCLUDES[@]}" \
    --dryrun 2>/dev/null > "$DRYRUN_OUTPUT" &
DRYRUN_PID=$!

# Wait up to DISCOVERY_TIMEOUT seconds
WAITED=0
while kill -0 "$DRYRUN_PID" 2>/dev/null; do
    if [ "$WAITED" -ge "$DISCOVERY_TIMEOUT" ]; then
        echo "Discovery timed out after ${DISCOVERY_TIMEOUT}s, skipping file count"
        kill "$DRYRUN_PID" 2>/dev/null
        wait "$DRYRUN_PID" 2>/dev/null
        DISCOVERY_SKIPPED=true
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done

# If dryrun completed in time, parse its output
if [ "$DISCOVERY_SKIPPED" = false ]; then
    wait "$DRYRUN_PID"
    DRYRUN_EXIT=$?
    if [ "$DRYRUN_EXIT" -eq 0 ]; then
        FILES_TOTAL=$(grep -c "download:" "$DRYRUN_OUTPUT" 2>/dev/null || echo "0")
        echo "Files to sync: $FILES_TOTAL"
    else
        echo "WARNING: Dryrun failed (exit $DRYRUN_EXIT), proceeding without file count"
    fi
fi

# Edge case: dryrun completed and found 0 files → already synced
if [ "$DISCOVERY_SKIPPED" = false ] && [ "$FILES_TOTAL" -eq 0 ]; then
    echo "No files to sync — already up to date"
    report_progress "already_synced" 0 0

    SYNC_STATUS=0
    SYNC_DURATION=0
    FINAL_STATUS="synced"

    # Jump to callback
    echo "=== Sync Complete (no-op) ==="
else
    # Report discovery results
    report_progress "syncing" 0 "$FILES_TOTAL"

    # ── Phase 2: Actual sync with progress tracking ──
    echo ""
    echo "=== Starting S3 Sync ==="
    SYNC_START=$(date +%s)

    # Progress counter file (written by awk, read by reporter)
    PROGRESS_FILE="/tmp/sync_progress"
    echo "0" > "$PROGRESS_FILE"

    # Background progress reporter: every 10s, POST current count
    if [ -n "$PROGRESS_CALLBACK_URL" ] && [ "$FILES_TOTAL" -gt 0 ]; then
        (
            while true; do
                sleep 10
                CURRENT=$(cat "$PROGRESS_FILE" 2>/dev/null || echo "0")
                report_progress "syncing" "$CURRENT" "$FILES_TOTAL"
            done
        ) &
        REPORTER_PID=$!
        echo "Progress reporter started (PID: $REPORTER_PID)"
    fi

    # Run sync, pipe through awk to count completed files
    aws s3 sync "s3://${SOURCE_VOLUME_ID}/" "${TARGET_DIR}/" \
        --endpoint-url "$SOURCE_ENDPOINT" \
        --region "$REGION" \
        "${SYNC_EXCLUDES[@]}" \
        --no-progress \
        2>&1 | tee /tmp/sync.log | awk -v pf="$PROGRESS_FILE" '
            /download:/ {
                count++
                print count > pf
                close(pf)
            }
            { print }
        '

    SYNC_STATUS=${PIPESTATUS[0]}

    # Kill background reporter
    if [ -n "$REPORTER_PID" ]; then
        kill "$REPORTER_PID" 2>/dev/null
        wait "$REPORTER_PID" 2>/dev/null
    fi

    # Fallback: check for fatal errors in log if PIPESTATUS didn't capture it
    if [ $SYNC_STATUS -eq 0 ] && grep -q "fatal error" /tmp/sync.log; then
        echo "WARNING: Detected fatal error in log despite exit code 0"
        SYNC_STATUS=1
    fi

    SYNC_END=$(date +%s)
    SYNC_DURATION=$((SYNC_END - SYNC_START))

    echo ""
    echo "=== Sync Complete ==="
    echo "Duration: ${SYNC_DURATION}s"
    echo "Exit code: ${SYNC_STATUS}"

    # Determine final status
    if [ $SYNC_STATUS -eq 0 ]; then
        FINAL_STATUS="synced"
        echo "Status: SUCCESS"
        # Report 100% completion
        report_progress "syncing" "$FILES_TOTAL" "$FILES_TOTAL"
    else
        FINAL_STATUS="failed"
        echo "Status: FAILED"
    fi
fi

# ── Phase 3: Send completion callback ──
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

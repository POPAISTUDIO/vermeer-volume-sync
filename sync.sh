#!/bin/bash
set -o pipefail

echo "=== Vermeer Volume Sync (rclone) ==="
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

TARGET_DIR="${TARGET_DIR:-/workspace}"
echo "Source: :s3:${SOURCE_VOLUME_ID}/"
echo "Target: ${TARGET_DIR}"

# ── Configure rclone S3 backend ──
cat > /tmp/rclone.conf << EOF
[source]
type = s3
provider = Other
access_key_id = ${S3_ACCESS_KEY}
secret_access_key = ${S3_SECRET_KEY}
endpoint = ${SOURCE_ENDPOINT}
region = ${REGION}
force_path_style = true
no_check_bucket = true
EOF

RCLONE_FLAGS=(
    --config /tmp/rclone.conf
    --stats 10s
    --stats-log-level NOTICE
    --use-json-log
    --transfers 8
    --checkers 16
    --exclude ".venv/**"
    --exclude "__pycache__/**"
    --exclude "*.pyc"
    --exclude "node_modules/**"
    --exclude ".cache/**"
    --exclude ".tmp/**"
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

echo ""
echo "=== Starting ==="
SYNC_START=$(date +%s)
report_progress "syncing" 0 0

# Track last known stats for final report
LAST_STATS="/tmp/last_stats"
echo "0 0 0 0" > "$LAST_STATS"

# ── Run rclone sync — parse JSON stats from stderr ──
rclone sync "source:${SOURCE_VOLUME_ID}/" "${TARGET_DIR}/" \
    "${RCLONE_FLAGS[@]}" \
    2>&1 | while IFS= read -r line; do
        # Identify stats lines by the presence of .stats key
        STATS=$(echo "$line" | jq -c '.stats // empty' 2>/dev/null)
        if [ -n "$STATS" ] && [ "$STATS" != "null" ]; then
            TRANSFERS=$(echo "$STATS" | jq '.transfers // 0')
            TOTAL_TRANSFERS=$(echo "$STATS" | jq '.totalTransfers // 0')
            BYTES=$(echo "$STATS" | jq '.bytes // 0')
            TOTAL_BYTES=$(echo "$STATS" | jq '.totalBytes // 0')
            SPEED=$(echo "$STATS" | jq '.speed // 0')
            ETA=$(echo "$STATS" | jq '.eta // 0')
            CHECKS=$(echo "$STATS" | jq '.checks // 0')
            TOTAL_CHECKS=$(echo "$STATS" | jq '.totalChecks // 0')

            # Persist for final report (while loop runs in subshell)
            echo "$TRANSFERS $TOTAL_TRANSFERS $CHECKS $TOTAL_CHECKS" > "$LAST_STATS"

            # Human-readable progress line
            if [ "$TOTAL_BYTES" -gt 0 ]; then
                BYTES_MB=$((BYTES / 1048576))
                TOTAL_MB=$((TOTAL_BYTES / 1048576))
                SPEED_MB=$(echo "$SPEED" | awk '{printf "%d", $1/1048576}')
                ETA_S=$(echo "$ETA" | awk '{printf "%d", $1}')
                PCT=$((BYTES * 100 / TOTAL_BYTES))
                echo "[progress] ${TRANSFERS}/${TOTAL_TRANSFERS} files, ${BYTES_MB}/${TOTAL_MB} MB, ${PCT}%, ${SPEED_MB} MB/s, ETA ${ETA_S}s"
                report_progress "syncing" "$TRANSFERS" "$TOTAL_TRANSFERS"
            elif [ "$TOTAL_TRANSFERS" -gt 0 ]; then
                PCT=$((TRANSFERS * 100 / TOTAL_TRANSFERS))
                echo "[progress] ${TRANSFERS}/${TOTAL_TRANSFERS} files (${PCT}%)"
                report_progress "syncing" "$TRANSFERS" "$TOTAL_TRANSFERS"
            elif [ "$TOTAL_CHECKS" -gt 0 ]; then
                echo "[progress] checking ${CHECKS}/${TOTAL_CHECKS}..."
                report_progress "discovering" "$CHECKS" "$TOTAL_CHECKS"
            else
                echo "[progress] starting..."
            fi
        else
            # Non-stats: show errors and warnings only
            LEVEL=$(echo "$line" | jq -r '.level // empty' 2>/dev/null)
            MSG=$(echo "$line" | jq -r '.msg // empty' 2>/dev/null)
            if [ -n "$MSG" ]; then
                case "$LEVEL" in
                    error)   echo "[ERROR] $MSG" ;;
                    warning) echo "[WARN]  $MSG" ;;
                esac
            fi
        fi
    done

SYNC_STATUS=${PIPESTATUS[0]}

# Read last known stats from the subshell
read FINAL_TRANSFERS FINAL_TOTAL_TRANSFERS FINAL_CHECKS FINAL_TOTAL_CHECKS < "$LAST_STATS" 2>/dev/null || true
FINAL_TRANSFERS=${FINAL_TRANSFERS:-0}
FINAL_TOTAL_TRANSFERS=${FINAL_TOTAL_TRANSFERS:-0}
FINAL_CHECKS=${FINAL_CHECKS:-0}
FINAL_TOTAL_CHECKS=${FINAL_TOTAL_CHECKS:-0}

# ── Results ──
SYNC_END=$(date +%s)
SYNC_DURATION=$((SYNC_END - SYNC_START))

echo ""
echo "=== Sync Complete ==="
echo "Duration: ${SYNC_DURATION}s"
echo "Files transferred: ${FINAL_TRANSFERS} / ${FINAL_TOTAL_TRANSFERS}"
echo "Files checked: ${FINAL_CHECKS} / ${FINAL_TOTAL_CHECKS}"
echo "Exit code: ${SYNC_STATUS}"

if [ $SYNC_STATUS -eq 0 ]; then
    FINAL_STATUS="synced"
    echo "Status: SUCCESS"
    # Report 100%
    if [ "$FINAL_TOTAL_TRANSFERS" -gt 0 ]; then
        report_progress "syncing" "$FINAL_TOTAL_TRANSFERS" "$FINAL_TOTAL_TRANSFERS"
    elif [ "$FINAL_TOTAL_CHECKS" -gt 0 ]; then
        report_progress "syncing" "$FINAL_TOTAL_CHECKS" "$FINAL_TOTAL_CHECKS"
    else
        report_progress "syncing" 1 1
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

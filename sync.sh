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

# Run sync
echo ""
echo "=== Starting S3 Sync ==="
SYNC_START=$(date +%s)

# Use pipefail to capture aws exit code through the pipe
aws s3 sync "s3://${SOURCE_VOLUME_ID}/" "${TARGET_DIR}/" \
    --endpoint-url "$SOURCE_ENDPOINT" \
    --no-progress \
    2>&1 | tee /tmp/sync.log

SYNC_STATUS=${PIPESTATUS[0]}
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
else
    FINAL_STATUS="failed"
    echo "Status: FAILED"
fi

# Send callback if URL provided
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

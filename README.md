# Vermeer Volume Sync

A lightweight Docker image for syncing RunPod network volumes using the S3-compatible API.

## Usage

This image is designed to run as a one-off pod on RunPod to sync data from a master volume to a slave volume.

### Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `S3_ACCESS_KEY` | Yes | RunPod user ID |
| `S3_SECRET_KEY` | Yes | RunPod S3 API secret |
| `SOURCE_ENDPOINT` | Yes | Source datacenter S3 endpoint (e.g., `https://s3api-eu-ro-1.runpod.io`) |
| `SOURCE_VOLUME_ID` | Yes | Source volume ID (bucket name) |
| `CALLBACK_URL` | No | Webhook URL to notify on completion |
| `JOB_ID` | No | Job identifier for callback payload |
| `TARGET_DIR` | No | Target directory (default: `/workspace`) |

### Callback Payload

When `CALLBACK_URL` is provided, the sync sends a POST request on completion:

```json
{
  "job_id": "abc123",
  "status": "synced",
  "duration_seconds": 120,
  "completed_at": "2024-01-15T10:30:00Z"
}
```

Status values: `synced` (success) or `failed` (error)

### RunPod Pod Configuration

When creating a pod via RunPod API:

```json
{
  "name": "volume-sync-job",
  "imageName": "ghcr.io/popaistudio/vermeer-volume-sync:main",
  "gpuTypeId": "NVIDIA GeForce RTX 3070",
  "volumeId": "slave-volume-id",
  "volumeMountPath": "/workspace",
  "env": {
    "S3_ACCESS_KEY": "your-runpod-user-id",
    "S3_SECRET_KEY": "your-s3-api-secret",
    "SOURCE_ENDPOINT": "https://s3api-eu-ro-1.runpod.io",
    "SOURCE_VOLUME_ID": "master-volume-id",
    "CALLBACK_URL": "https://your-app.com/api/sync-callback",
    "JOB_ID": "sync-job-123"
  }
}
```

## Building Locally

```bash
docker build -t vermeer-volume-sync .
```

## Testing Locally

```bash
docker run --rm \
  -e S3_ACCESS_KEY=your-key \
  -e S3_SECRET_KEY=your-secret \
  -e SOURCE_ENDPOINT=https://s3api-eu-ro-1.runpod.io \
  -e SOURCE_VOLUME_ID=your-volume-id \
  -v /tmp/test-sync:/workspace \
  vermeer-volume-sync
```

## Supported Datacenters

RunPod S3 API is available in these datacenters:
- EUR-IS-1, EUR-NO-1, EU-RO-1, EU-CZ-1
- US-CA-2, US-GA-2, US-KS-2, US-MD-1, US-MO-2, US-NC-1, US-NC-2

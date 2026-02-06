FROM alpine:3.19

# Install dependencies
RUN apk add --no-cache \
    aws-cli \
    curl \
    bash \
    jq

# Copy sync script
COPY sync.sh /sync.sh
RUN chmod +x /sync.sh

# Default environment variables
ENV S3_ACCESS_KEY=""
ENV S3_SECRET_KEY=""
ENV SOURCE_ENDPOINT=""
ENV SOURCE_VOLUME_ID=""
ENV CALLBACK_URL=""
ENV JOB_ID=""

ENTRYPOINT ["/sync.sh"]

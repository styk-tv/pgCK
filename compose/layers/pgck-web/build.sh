#!/bin/bash
# Local pgck-web OCI layer build script
# Mirrors release build workflow; output can be tested locally before GitHub Actions

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WEB_DIR="$PROJECT_ROOT/web"
OUTPUT_DIR="$SCRIPT_DIR/output"

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) ARCH_TAG="amd64" ;;
  arm64|aarch64) ARCH_TAG="arm64" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

VERSION="${1:-dev}"
IMAGE_NAME="pgck-web:${VERSION}-${ARCH_TAG}"
TAR_OUTPUT="$OUTPUT_DIR/pgck-web-${VERSION}-${ARCH_TAG}.oci.tar"

echo "[pgck-web build] Architecture: $ARCH_TAG"
echo "[pgck-web build] Version: $VERSION"
echo "[pgck-web build] Building: $IMAGE_NAME"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Build OCI image
cd "$WEB_DIR"
docker build -f Dockerfile.pgck-web -t "$IMAGE_NAME" .

echo "[pgck-web build] Image built: $IMAGE_NAME"
echo "[pgck-web build] To push to registry, use:"
echo "  docker tag $IMAGE_NAME ghcr.io/styk-tv/$IMAGE_NAME"
echo "  docker push ghcr.io/styk-tv/$IMAGE_NAME"

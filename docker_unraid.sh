#!/bin/bash

# Docker static binaries directory URL
BASE_URL="https://download.docker.com/linux/static/stable/x86_64/"

# Fetch the latest Docker version from the directory listing
LATEST_FILE=$(curl -s "$BASE_URL" | grep -oP 'docker-\d+\.\d+\.\d+\.tgz' | sort -V | tail -n 1)

# Check if the latest file was found
if [ -z "$LATEST_FILE" ]; then
  echo "Failed to find the latest Docker static binary."
  exit 1
fi

# Full URL of the latest Docker tarball
LATEST_URL="$BASE_URL$LATEST_FILE"

# Download the Docker static binary tarball
echo "Downloading Docker from $LATEST_URL..."
curl -LO "$LATEST_URL"

# Unpack the tarball into /usr/bin, overwriting existing files
echo "Extracting $LATEST_FILE to /usr/bin and overwriting existing files..."
sudo tar --overwrite --strip-components=1 -xvzf "$LATEST_FILE" -C /usr/bin

# Clean up the downloaded tarball
echo "Cleaning up..."
rm -f "$LATEST_FILE"

echo "Docker has been successfully installed into /usr/bin."

# Install or update Docker Buildx from GitHub
BUILDX_URL=$(curl -s https://api.github.com/repos/docker/buildx/releases/latest \
             | grep "browser_download_url.*linux-amd64\"" \
             | grep -v '\.json' \
             | cut -d '"' -f 4)

# Check if the Buildx URL was found
if [ -z "$BUILDX_URL" ]; then
  echo "Failed to find the latest Docker Buildx binary."
  exit 1
fi

# Download the latest Buildx binary
echo "Downloading Docker Buildx from $BUILDX_URL..."
curl -LO "$BUILDX_URL"

# Extract the Buildx binary filename
BUILDX_BIN=$(basename "$BUILDX_URL")

# Make the binary executable and move it to the Docker plugins directory
echo "Installing Docker Buildx..."
sudo mkdir -p /usr/libexec/docker/cli-plugins
sudo mv -f "$BUILDX_BIN" /usr/libexec/docker/cli-plugins/docker-buildx
sudo chmod +x /usr/libexec/docker/cli-plugins/docker-buildx

echo "Docker Buildx has been successfully installed/updated."

#!/bin/bash

set -Eeuo pipefail
shopt -s nullglob

# Docker static binaries and Docker Buildx release sources
readonly BASE_URL="https://download.docker.com/linux/static/stable/x86_64/"
readonly BUILDX_API="https://api.github.com/repos/docker/buildx/releases/latest"

# Keep the two latest downloaded versions in a cache beside this script
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly CACHE_DIR="$SCRIPT_DIR/cache/docker"
readonly DOCKER_CACHE="$CACHE_DIR/docker"
readonly BUILDX_CACHE="$CACHE_DIR/buildx"

# Retry transient failures and fail quickly on connection or stalled-transfer errors
readonly -a CURL_OPTIONS=(
  --fail
  --location
  --silent
  --show-error
  --connect-timeout 3
  --speed-limit 1
  --speed-time 3
  --retry 10
  --retry-delay 2
  --retry-all-errors
)

# Headers shared by all GitHub REST API requests
readonly -a GITHUB_API_OPTIONS=(
  --header "Accept: application/vnd.github+json"
  --header "X-GitHub-Api-Version: 2026-03-10"
)

TMP_DIR=""
SELECTED_CACHE_FILE=""

# Remove incomplete downloads and extracted files on every exit
cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}

on_error() {
  local exit_code=$?
  local line_number=$1
  echo "Error: Docker installation failed at line ${line_number} (exit ${exit_code})." >&2
  exit "$exit_code"
}

# Return the newest version from one component cache
latest_cached() {
  local directory=$1
  local pattern=$2
  local -a files=("$directory"/$pattern)

  ((${#files[@]} > 0)) || return 1
  printf '%s\n' "${files[@]}" | sort -V | tail -n 1
}

# Keep only the two latest cached versions of a component
prune_cache() {
  local directory=$1
  local pattern=$2
  local -a files=("$directory"/$pattern)
  local -a sorted=()
  local remove_count index

  ((${#files[@]} > 2)) || return 0
  mapfile -t sorted < <(printf '%s\n' "${files[@]}" | sort -V)
  remove_count=$((${#sorted[@]} - 2))
  for ((index = 0; index < remove_count; index++)); do
    rm -f -- "${sorted[index]}"
  done
}

# Select the newest valid cache entry, removing corrupt entries as needed
select_cached_fallback() {
  local directory=$1
  local pattern=$2
  local label=$3
  local validator=$4
  local cached_file
  shift 4

  SELECTED_CACHE_FILE=""
  while cached_file=$(latest_cached "$directory" "$pattern"); do
    if "$validator" "$cached_file" "$@"; then
      SELECTED_CACHE_FILE="$cached_file"
      echo "Using cached $label: $(basename "$cached_file")"
      return 0
    fi
    echo "Warning: removing invalid $label cache file: $cached_file" >&2
    rm -f -- "$cached_file"
  done
  return 1
}

# Validate cached or downloaded Docker archives before using them
valid_docker_archive() {
  local archive=$1
  local listing

  listing=$(tar -tzf "$archive" 2>/dev/null) || return 1
  grep -qx 'docker/docker' <<<"$listing" && grep -qx 'docker/dockerd' <<<"$listing"
}

# Buildx is distributed as a Linux ELF executable
valid_buildx_binary() {
  local binary=$1
  [[ -s "$binary" ]] && [[ $(head -c 4 "$binary" | od -An -tx1 | tr -d ' \n') == "7f454c46" ]]
}

trap 'on_error "$LINENO"' ERR
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Unraid host binaries must be installed as root
if ((EUID != 0)); then
  echo "Error: run this script as root on the Unraid host." >&2
  exit 1
fi

for command_name in curl grep cut sort tail tar install mktemp head od tr; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Error: required command not found: $command_name" >&2
    exit 1
  fi
done

# Create persistent component caches and an isolated working directory
mkdir -p "$DOCKER_CACHE" "$BUILDX_CACHE"
TMP_DIR=$(mktemp -d /tmp/docker-unraid.XXXXXX)

# Fetch the latest Docker version from the directory listing
docker_archive=""
echo "Checking for the latest Docker static release..."
if docker_index=$(curl "${CURL_OPTIONS[@]}" "$BASE_URL"); then
  latest_file=$(
    grep -oE 'docker-[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?\.tgz' <<<"$docker_index" |
      sort -Vu |
      tail -n 1
  ) || latest_file=""

  if [[ -n "$latest_file" ]]; then
    cached_file="$DOCKER_CACHE/$latest_file"

    # Skip the download when the latest release is already cached and valid
    if [[ -f "$cached_file" ]] && valid_docker_archive "$cached_file"; then
      echo "Using cached latest Docker release: $latest_file"
      docker_archive="$cached_file"
    else
      download_file="$TMP_DIR/$latest_file"
      echo "Downloading Docker release: $latest_file"
      if curl "${CURL_OPTIONS[@]}" --output "$download_file" "${BASE_URL}${latest_file}" &&
        valid_docker_archive "$download_file"; then
        mv "$download_file" "$cached_file"
        docker_archive="$cached_file"
      else
        echo "Warning: Docker download failed; trying the newest cached release." >&2
      fi
    fi
  else
    echo "Warning: Docker release metadata was invalid; trying the cache." >&2
  fi
else
  echo "Warning: Docker release lookup failed; trying the cache." >&2
fi

# If lookup or download failed, use the latest valid cached Docker release
if [[ -z "$docker_archive" ]]; then
  if select_cached_fallback \
    "$DOCKER_CACHE" \
    'docker-*.tgz' \
    "Docker release" \
    valid_docker_archive; then
    docker_archive="$SELECTED_CACHE_FILE"
  fi
fi

# Do not modify the host when neither an online nor cached release is available
if [[ -z "$docker_archive" ]]; then
  echo "Error: Docker is unavailable online and no valid cached release exists in $DOCKER_CACHE." >&2
  exit 1
fi

# Install or update Docker Buildx from the latest GitHub release
buildx_binary=""
echo "Checking for the latest Docker Buildx release..."
if buildx_release=$(curl \
  "${CURL_OPTIONS[@]}" \
  "${GITHUB_API_OPTIONS[@]}" \
  "$BUILDX_API"); then
  buildx_url=$(
    grep -m 1 -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"https://[^"[:space:]]+\.linux-amd64"' <<<"$buildx_release" |
      cut -d '"' -f 4
  ) || buildx_url=""

  if [[ -n "$buildx_url" ]]; then
    buildx_name=$(basename "$buildx_url")
    cached_file="$BUILDX_CACHE/$buildx_name"

    # Skip the download when the latest Buildx release is already cached
    if [[ -f "$cached_file" ]] && valid_buildx_binary "$cached_file"; then
      echo "Using cached latest Buildx release: $buildx_name"
      buildx_binary="$cached_file"
    else
      download_file="$TMP_DIR/$buildx_name"
      echo "Downloading Buildx release: $buildx_name"
      if curl "${CURL_OPTIONS[@]}" --output "$download_file" "$buildx_url" &&
        valid_buildx_binary "$download_file"; then
        mv "$download_file" "$cached_file"
        buildx_binary="$cached_file"
      else
        echo "Warning: Buildx download failed; trying the newest cached release." >&2
      fi
    fi
  else
    echo "Warning: Buildx release metadata was invalid; trying the cache." >&2
  fi
else
  echo "Warning: Buildx release lookup failed; trying the cache." >&2
fi

# If GitHub is unavailable, use the latest valid cached Buildx binary
if [[ -z "$buildx_binary" ]]; then
  if select_cached_fallback \
    "$BUILDX_CACHE" \
    'buildx-*.linux-amd64' \
    "Buildx release" \
    valid_buildx_binary; then
    buildx_binary="$SELECTED_CACHE_FILE"
  fi
fi

if [[ -z "$buildx_binary" ]]; then
  echo "Error: Buildx is unavailable online and no valid cached release exists in $BUILDX_CACHE." >&2
  exit 1
fi

# Keep both component caches bounded to their two latest versions
prune_cache "$DOCKER_CACHE" 'docker-*.tgz'
prune_cache "$BUILDX_CACHE" 'buildx-*.linux-amd64'

# Unpack the validated Docker archive into a temporary directory
docker_extract_dir="$TMP_DIR/docker-extract"
mkdir -p "$docker_extract_dir"
tar -xzf "$docker_archive" -C "$docker_extract_dir"

echo "Installing Docker binaries from $(basename "$docker_archive")..."

# Install Docker into /usr/bin, overwriting the existing host binaries
for binary_path in "$docker_extract_dir"/docker/*; do
  [[ -f "$binary_path" ]] || continue
  install -m 0755 "$binary_path" "/usr/bin/$(basename "$binary_path")"
done

# Install Buildx in Docker's CLI plugin directory
mkdir -p /usr/libexec/docker/cli-plugins
install -m 0755 "$buildx_binary" /usr/libexec/docker/cli-plugins/docker-buildx

echo "Docker and Docker Buildx were installed successfully."
echo "Cache location: $CACHE_DIR"

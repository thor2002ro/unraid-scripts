#!/bin/bash

set -Eeuo pipefail
shopt -s nullglob

export HOME=/root

# Define the Slackware mirror, package directory, and Fastfetch release source
readonly MIRROR="https://mirrors.slackware.com/slackware/slackware64-current/slackware64"
readonly PACKAGE_DIR="ap"
readonly FASTFETCH_API="https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest"

# Keep the two latest versions of every component beside this script
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly CACHE_DIR="$SCRIPT_DIR/cache/zsh"

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

readonly OH_MY_ZSH_ROOT="$HOME/.oh-my-zsh"
readonly ZSH_CUSTOM="$OH_MY_ZSH_ROOT/custom"
readonly OH_MY_ZSH_PLUGINS="$ZSH_CUSTOM/plugins"
readonly FASTFETCH_DIR="$HOME/fastfetch"

TMP_DIR=""
RESOLVED_FILE=""
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
  echo "Error: Zsh setup failed at line ${line_number} (exit ${exit_code})." >&2
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

# Validate a compressed release archive and its expected contents
valid_tar_archive() {
  local archive=$1
  local expected_path=$2
  local listing

  listing=$(tar -tzf "$archive" 2>/dev/null) || return 1
  grep -Fq "/$expected_path" <<<"$listing"
}

# Slackware packages are tar archives compressed with xz
valid_zsh_package() {
  tar -tf "$1" >/dev/null 2>&1
}

# Resolve a Git branch to its commit SHA, caching two revisions for offline use
resolve_branch_archive() {
  local component=$1
  local repository=$2
  local branch=$3
  local expected_path=$4
  local component_cache="$CACHE_DIR/$component"
  local api_url="https://api.github.com/repos/$repository/commits/$branch"
  local metadata sha archive_url timestamp cache_file download_file
  local -a matching_files=()

  RESOLVED_FILE=""
  mkdir -p "$component_cache"

  echo "Checking for the latest $component revision..."
  if metadata=$(curl \
    "${CURL_OPTIONS[@]}" \
    "${GITHUB_API_OPTIONS[@]}" \
    "$api_url"); then
    sha=$(
      grep -m 1 -oE '"sha"[[:space:]]*:[[:space:]]*"[0-9a-f]{40}"' <<<"$metadata" |
        cut -d '"' -f 4
    ) || sha=""

    if [[ -n "$sha" ]]; then
      matching_files=("$component_cache"/"$component"-*-"$sha".tar.gz)

      # Compare the remote commit with cached revisions before downloading
      if ((${#matching_files[@]} > 0)) &&
        valid_tar_archive "${matching_files[0]}" "$expected_path"; then
        RESOLVED_FILE="${matching_files[0]}"
        echo "Using cached latest $component revision: ${sha:0:12}"
      else
        timestamp=$(date +%s)
        cache_file="$component_cache/$component-$timestamp-$sha.tar.gz"
        download_file="$TMP_DIR/$component-$sha.tar.gz"
        archive_url="https://github.com/$repository/archive/$sha.tar.gz"
        echo "Downloading $component revision: ${sha:0:12}"
        if curl "${CURL_OPTIONS[@]}" --output "$download_file" "$archive_url" &&
          valid_tar_archive "$download_file" "$expected_path"; then
          mv "$download_file" "$cache_file"
          RESOLVED_FILE="$cache_file"
        else
          echo "Warning: $component download failed; trying the newest cached revision." >&2
        fi
      fi
    else
      echo "Warning: $component metadata was invalid; trying the cache." >&2
    fi
  else
    echo "Warning: $component lookup failed; trying the cache." >&2
  fi

  # If the lookup or download failed, use the newest valid cached revision
  if [[ -z "$RESOLVED_FILE" ]]; then
    if select_cached_fallback \
      "$component_cache" \
      "$component-*.tar.gz" \
      "$component revision" \
      valid_tar_archive \
      "$expected_path"; then
      RESOLVED_FILE="$SELECTED_CACHE_FILE"
    fi
  fi

  if [[ -z "$RESOLVED_FILE" ]]; then
    echo "Error: $component is unavailable online and has no valid cached revision in $component_cache." >&2
    return 1
  fi

  prune_cache "$component_cache" "$component-*.tar.gz"
}

# Install the selected cached revision and preserve an optional data directory
install_cached_archive() {
  local archive=$1
  local destination=$2
  local expected_path=$3
  local preserve_path=${4:-}
  local extract_dir="$TMP_DIR/extract-$RANDOM"
  local backup_dir="$TMP_DIR/backup-$RANDOM"
  local source_dir cache_identity installed_identity=""

  mkdir -p "$extract_dir"
  tar -xzf "$archive" -C "$extract_dir"
  source_dir=$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d -print -quit)

  if [[ -z "$source_dir" || ! -e "$source_dir/$expected_path" ]]; then
    echo "Error: cached archive $(basename "$archive") has an unexpected layout." >&2
    return 1
  fi

  cache_identity=$(basename "$archive")
  if [[ -f "$destination/.unraid-cache-source" ]]; then
    installed_identity=$(<"$destination/.unraid-cache-source")
  fi

  if [[ "$installed_identity" == "$cache_identity" && -e "$destination/$expected_path" ]]; then
    echo "  -> $destination already has revision $cache_identity"
    return 0
  fi

  printf '%s\n' "$cache_identity" >"$source_dir/.unraid-cache-source"
  mkdir -p "$(dirname "$destination")"

  # Move the old installation aside so a failed replacement can be restored
  if [[ -e "$destination" ]]; then
    mv "$destination" "$backup_dir"
  fi

  if ! mv "$source_dir" "$destination"; then
    rm -rf -- "$destination"
    [[ ! -e "$backup_dir" ]] || mv "$backup_dir" "$destination"
    return 1
  fi

  # Preserve Oh My Zsh custom content while updating the managed core files
  if [[ -n "$preserve_path" && -e "$backup_dir/$preserve_path" ]]; then
    rm -rf -- "$destination/$preserve_path"
    mkdir -p "$(dirname "$destination/$preserve_path")"
    if ! mv "$backup_dir/$preserve_path" "$destination/$preserve_path"; then
      rm -rf -- "$destination"
      mv "$backup_dir" "$destination"
      return 1
    fi
  fi

  echo "  -> installed revision $cache_identity into $destination"
}

trap 'on_error "$LINENO"' ERR
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Unraid host packages and root configuration must be installed as root
if ((EUID != 0)); then
  echo "Error: run this script as root on the Unraid host." >&2
  exit 1
fi

for command_name in curl grep cut sort tail tar upgradepkg chsh install mktemp find date; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Error: required command not found: $command_name" >&2
    exit 1
  fi
done

# Create persistent caches and an isolated working directory
mkdir -p "$CACHE_DIR/zsh-package" "$CACHE_DIR/fastfetch"
TMP_DIR=$(mktemp -d /tmp/zsh-unraid.XXXXXX)

# Fetch the latest Zsh package name from the Slackware package listing
zsh_package=""
echo "Checking for the latest Zsh package..."
if package_index=$(curl "${CURL_OPTIONS[@]}" "$MIRROR/$PACKAGE_DIR/"); then
  latest_package=$(
    grep -oE 'zsh-[0-9]+(\.[0-9]+)*-x86_64-[0-9]+\.txz' <<<"$package_index" |
      sort -Vu |
      tail -n 1
  ) || latest_package=""

  if [[ -n "$latest_package" ]]; then
    cache_file="$CACHE_DIR/zsh-package/$latest_package"

    # Skip the download when the latest Zsh package is already cached
    if [[ -f "$cache_file" ]] && valid_zsh_package "$cache_file"; then
      zsh_package="$cache_file"
      echo "Using cached latest Zsh package: $latest_package"
    else
      download_file="$TMP_DIR/$latest_package"
      echo "Downloading Zsh package: $latest_package"
      if curl "${CURL_OPTIONS[@]}" --output "$download_file" "$MIRROR/$PACKAGE_DIR/$latest_package" &&
        valid_zsh_package "$download_file"; then
        mv "$download_file" "$cache_file"
        zsh_package="$cache_file"
      else
        echo "Warning: Zsh download failed; trying the newest cached package." >&2
      fi
    fi
  else
    echo "Warning: Zsh package metadata was invalid; trying the cache." >&2
  fi
else
  echo "Warning: Zsh package lookup failed; trying the cache." >&2
fi

# If the mirror is unavailable, use the newest valid cached Zsh package
if [[ -z "$zsh_package" ]]; then
  if select_cached_fallback \
    "$CACHE_DIR/zsh-package" \
    'zsh-*.txz' \
    "Zsh package" \
    valid_zsh_package; then
    zsh_package="$SELECTED_CACHE_FILE"
  fi
fi

if [[ -z "$zsh_package" ]]; then
  echo "Error: Zsh is unavailable online and no valid cached package exists in $CACHE_DIR/zsh-package." >&2
  exit 1
fi
prune_cache "$CACHE_DIR/zsh-package" 'zsh-*.txz'

# Cache Oh My Zsh by commit so it can be installed without internet access
resolve_branch_archive "ohmyzsh" "ohmyzsh/ohmyzsh" "master" "oh-my-zsh.sh"
ohmyzsh_archive="$RESOLVED_FILE"

# Install or update the zsh-autosuggestions cache
resolve_branch_archive \
  "zsh-autosuggestions" \
  "zsh-users/zsh-autosuggestions" \
  "master" \
  "zsh-autosuggestions.plugin.zsh"
autosuggestions_archive="$RESOLVED_FILE"

# Install or update the zsh-syntax-highlighting cache
resolve_branch_archive \
  "zsh-syntax-highlighting" \
  "zsh-users/zsh-syntax-highlighting" \
  "master" \
  "zsh-syntax-highlighting.plugin.zsh"
syntax_highlighting_archive="$RESOLVED_FILE"

# Download and cache the latest Fastfetch release
fastfetch_archive=""
echo "Checking for the latest Fastfetch release..."
if fastfetch_release=$(curl \
  "${CURL_OPTIONS[@]}" \
  "${GITHUB_API_OPTIONS[@]}" \
  "$FASTFETCH_API"); then
  fastfetch_tag=$(
    grep -m 1 -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"[:space:]]+"' <<<"$fastfetch_release" |
      cut -d '"' -f 4
  ) || fastfetch_tag=""
  fastfetch_url=$(
    grep -m 1 -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"https://[^"[:space:]]+/fastfetch-linux-amd64\.tar\.gz"' <<<"$fastfetch_release" |
      cut -d '"' -f 4
  ) || fastfetch_url=""

  if [[ -n "$fastfetch_tag" && -n "$fastfetch_url" ]]; then
    safe_tag=${fastfetch_tag//\//_}
    cache_file="$CACHE_DIR/fastfetch/fastfetch-$safe_tag-linux-amd64.tar.gz"

    # Compare the remote release tag with cached versions before downloading
    if [[ -f "$cache_file" ]] && valid_tar_archive "$cache_file" "usr/bin/fastfetch"; then
      fastfetch_archive="$cache_file"
      echo "Using cached latest Fastfetch release: $fastfetch_tag"
    else
      download_file="$TMP_DIR/fastfetch-$safe_tag.tar.gz"
      echo "Downloading Fastfetch release: $fastfetch_tag"
      if curl "${CURL_OPTIONS[@]}" --output "$download_file" "$fastfetch_url" &&
        valid_tar_archive "$download_file" "usr/bin/fastfetch"; then
        mv "$download_file" "$cache_file"
        fastfetch_archive="$cache_file"
      else
        echo "Warning: Fastfetch download failed; trying the newest cached release." >&2
      fi
    fi
  else
    echo "Warning: Fastfetch metadata was invalid; trying the cache." >&2
  fi
else
  echo "Warning: Fastfetch lookup failed; trying the cache." >&2
fi

# If GitHub is unavailable, use the newest valid cached Fastfetch release
if [[ -z "$fastfetch_archive" ]]; then
  if select_cached_fallback \
    "$CACHE_DIR/fastfetch" \
    'fastfetch-*-linux-amd64.tar.gz' \
    "Fastfetch release" \
    valid_tar_archive \
    "usr/bin/fastfetch"; then
    fastfetch_archive="$SELECTED_CACHE_FILE"
  fi
fi

if [[ -z "$fastfetch_archive" ]]; then
  echo "Error: Fastfetch is unavailable online and no valid cached release exists in $CACHE_DIR/fastfetch." >&2
  exit 1
fi
prune_cache "$CACHE_DIR/fastfetch" 'fastfetch-*-linux-amd64.tar.gz'

# Install Zsh when missing, or upgrade/downgrade the existing package safely
echo "Installing Zsh from $(basename "$zsh_package")..."
upgradepkg --install-new "$zsh_package"
if [[ ! -x /bin/zsh ]]; then
  echo "Error: /bin/zsh was not installed." >&2
  exit 1
fi

# Install Oh My Zsh and its plugins from their selected cache entries
echo "Installing Oh My Zsh and plugins..."
install_cached_archive "$ohmyzsh_archive" "$OH_MY_ZSH_ROOT" "oh-my-zsh.sh" "custom"
mkdir -p "$OH_MY_ZSH_PLUGINS" "$ZSH_CUSTOM/themes"
install_cached_archive \
  "$autosuggestions_archive" \
  "$OH_MY_ZSH_PLUGINS/zsh-autosuggestions" \
  "zsh-autosuggestions.plugin.zsh"
install_cached_archive \
  "$syntax_highlighting_archive" \
  "$OH_MY_ZSH_PLUGINS/zsh-syntax-highlighting" \
  "zsh-syntax-highlighting.plugin.zsh"

# Extract and install Fastfetch
fastfetch_extract_dir="$TMP_DIR/fastfetch-extract"
mkdir -p "$fastfetch_extract_dir" "$FASTFETCH_DIR"
tar -xzf "$fastfetch_archive" -C "$fastfetch_extract_dir" --strip-components=1

if [[ ! -f "$fastfetch_extract_dir/usr/bin/fastfetch" ]]; then
  echo "Error: cached Fastfetch archive has an unexpected layout." >&2
  exit 1
fi

install -m 0755 "$fastfetch_extract_dir/usr/bin/fastfetch" "$FASTFETCH_DIR/fastfetch"
if [[ -f "$fastfetch_extract_dir/usr/bin/flashfetch" ]]; then
  install -m 0755 "$fastfetch_extract_dir/usr/bin/flashfetch" "$FASTFETCH_DIR/flashfetch"
fi

# Change the default root shell to Zsh
echo "Configuring Zsh..."
chsh -s /bin/zsh root

# Create the root .zshrc file
zshrc_file="$TMP_DIR/zshrc"
cat >"$zshrc_file" <<'EOF'
export ZSH="/root/.oh-my-zsh"

ZSH_THEME="robbyrussell"
DISABLE_UPDATE_PROMPT="true"

HISTSIZE=10000
SAVEHIST=10000
HISTFILE=/root/.cache/zsh/history

plugins=(
  zsh-autosuggestions
  zsh-syntax-highlighting
)

source "$ZSH/oh-my-zsh.sh"

# User configurations
alias l='ls -lFh'     # size, show type, human readable
alias la='ls -lAFh'   # long list, show almost all, show type, human readable
EOF

# Create the root .zshenv file
zshenv_file="$TMP_DIR/zshenv"
cat >"$zshenv_file" <<'EOF'
# Fastfetch command
FASTFETCH_DIR="/root/fastfetch"
if [[ -o interactive && -x "$FASTFETCH_DIR/fastfetch" ]]; then
  "$FASTFETCH_DIR/fastfetch" --gpu-temp true --cpu-temp true
fi
EOF

install -m 0600 "$zshrc_file" /root/.zshrc
install -m 0600 "$zshenv_file" /root/.zshenv

# Set up the persistent history directory and history file
mkdir -p /root/.cache/zsh /boot/config/extra
touch /boot/config/extra/history

# Symlink the persistent history file into root's Zsh cache
ln -sfn /boot/config/extra/history /root/.cache/zsh/history

echo "Zsh, Oh My Zsh, plugins, and Fastfetch were set up successfully."
echo "Cache location: $CACHE_DIR"

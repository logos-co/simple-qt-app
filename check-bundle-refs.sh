#!/usr/bin/env bash
# Check for hardcoded non-portable paths in macOS .app bundles and DMGs
# Usage: ./check-bundle-refs.sh [path ...]
# Default path: ./build/HelloWorld.app
#
# Detects absolute paths that would break on another machine, such as:
#   /usr/local/*, /opt/homebrew/*, /nix/store/*, /Users/*, /build/*, etc.
#
# Portable (allowed) paths:
#   @executable_path, @loader_path, @rpath
#   /System/Library/*, /usr/lib/*
#
# Supports: directories, .app bundles, .dmg disk images, individual binaries

set -euo pipefail

FOUND=0
TARGETS=("${@:-./build/HelloWorld.app}")
TEMP_DIRS=()
DMG_MOUNTPOINTS=()

cleanup() {
  for mp in "${DMG_MOUNTPOINTS[@]}"; do
    if mount | grep -q "$mp"; then
      echo ""
      echo "Unmounting $mp..."
      hdiutil detach "$mp" -quiet 2>/dev/null || true
    fi
  done
  for td in "${TEMP_DIRS[@]}"; do
    if [ -d "$td" ]; then
      rm -r "$td"
    fi
  done
}
trap cleanup EXIT

# Paths that are safe / expected on any macOS machine
is_portable_path() {
  local path="$1"
  # @-prefixed paths are relocatable
  [[ "$path" == @executable_path/* ]] && return 0
  [[ "$path" == @loader_path/* ]] && return 0
  [[ "$path" == @rpath/* ]] && return 0
  # System-provided libraries and frameworks
  [[ "$path" == /System/Library/* ]] && return 0
  [[ "$path" == /usr/lib/* ]] && return 0
  # Self-reference (just the library name, no path)
  [[ "$path" != */* ]] && return 0
  return 1
}

# ── Scan a single binary file ────────────────────────────────────────────────
scan_binary() {
  local file="$1"
  local header_printed=0

  print_header() {
    if [ "$header_printed" -eq 0 ]; then
      echo "--- $file ---"
      header_printed=1
    fi
  }

  # 1. Check linked libraries (otool -L)
  if command -v otool &>/dev/null; then
    local bad_libs=""
    while IFS= read -r line; do
      # Extract the library path (first token before " (compatibility")
      local lib_path
      lib_path=$(echo "$line" | sed 's/^[[:space:]]*//' | awk '{print $1}')
      [ -z "$lib_path" ] && continue
      if ! is_portable_path "$lib_path"; then
        bad_libs="${bad_libs}  ${line}"$'\n'
      fi
    done < <(otool -L "$file" 2>/dev/null | tail -n +2)

    if [ -n "$bad_libs" ]; then
      print_header
      echo "[otool -L] Non-portable library references:"
      echo -n "$bad_libs"
      FOUND=1
    fi
  fi

  # 2. Check RPATHs
  if command -v otool &>/dev/null; then
    local bad_rpaths=""
    while IFS= read -r rpath; do
      [ -z "$rpath" ] && continue
      if ! is_portable_path "$rpath"; then
        bad_rpaths="${bad_rpaths}  ${rpath}"$'\n'
      fi
    done < <(otool -l "$file" 2>/dev/null | awk '/LC_RPATH/{found=1} found && /path /{print $2; found=0}')

    if [ -n "$bad_rpaths" ]; then
      print_header
      echo "[otool -l] Non-portable RPATHs:"
      echo -n "$bad_rpaths"
      FOUND=1
    fi
  fi

  # 3. Check install name (dylibs only)
  if command -v otool &>/dev/null; then
    local install_name
    install_name=$(otool -D "$file" 2>/dev/null | tail -n +2 | head -1 || true)
    if [ -n "$install_name" ] && ! is_portable_path "$install_name"; then
      print_header
      echo "[otool -D] Non-portable install name:"
      echo "  $install_name"
      FOUND=1
    fi
  fi

  # 4. Check strings for common non-portable path patterns
  if command -v strings &>/dev/null; then
    local bad_strings
    bad_strings=$(strings "$file" 2>/dev/null | grep -E '^(/usr/local/|/opt/homebrew/|/opt/local/|/nix/store/|/Users/[^/]+/(lib|include|Qt|\.nix)|/build/)' | sort -u | head -20 || true)
    if [ -n "$bad_strings" ]; then
      print_header
      echo "[strings] Suspicious hardcoded paths in binary data:"
      echo "$bad_strings" | sed 's/^/  /'
      FOUND=1
    fi
  fi

  if [ "$header_printed" -eq 1 ]; then
    echo ""
  fi
}

# ── Scan all binaries under a directory ──────────────────────────────────────
scan_directory() {
  local dir="$1"
  local count=0

  while IFS= read -r -d '' file; do
    local filetype
    filetype=$(file "$file" 2>/dev/null || true)
    if echo "$filetype" | grep -qE 'Mach-O|ELF'; then
      scan_binary "$file"
      count=$((count + 1))
    fi
  done < <(find "$dir" -type f -print0 2>/dev/null)

  if [ "$count" -eq 0 ]; then
    echo "(no Mach-O or ELF binaries found under $dir)"
    echo ""
  else
    echo "Scanned $count binaries under $dir"
    echo ""
  fi
}

# ── Mount/extract a .dmg and scan its contents ──────────────────────────────
scan_dmg() {
  local dmg="$1"

  if command -v hdiutil &>/dev/null; then
    local mountpoint
    mountpoint=$(mktemp -d)
    TEMP_DIRS+=("$mountpoint")

    echo "Mounting DMG: $dmg -> $mountpoint ..."
    local mount_output
    mount_output=$(hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mountpoint" 2>&1) || {
      echo "Error: Failed to mount '$dmg':"
      echo "$mount_output"
      return 1
    }

    DMG_MOUNTPOINTS+=("$mountpoint")
    echo "Mounted at: $mountpoint"
    echo ""

    scan_directory "$mountpoint"
  else
    echo "Error: hdiutil not found. This script requires macOS."
    return 1
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
echo "Checking for non-portable hardcoded paths"
echo "Allowed: @executable_path, @loader_path, @rpath, /System/Library/*, /usr/lib/*"
echo ""

for TARGET in "${TARGETS[@]}"; do
  if [ ! -e "$TARGET" ]; then
    echo "Error: '$TARGET' does not exist."
    echo "Usage: $0 [path ...]"
    exit 1
  fi

  echo "Scanning '$TARGET'..."
  echo "======================================================="
  echo ""

  if [[ "$TARGET" == *.dmg ]]; then
    scan_dmg "$TARGET"
  elif [ -d "$TARGET" ]; then
    scan_directory "$TARGET"
  elif [ -f "$TARGET" ]; then
    filetype=$(file "$TARGET" 2>/dev/null || true)
    if echo "$filetype" | grep -qE 'Mach-O|ELF'; then
      scan_binary "$TARGET"
    else
      echo "Warning: '$TARGET' is not a Mach-O or ELF binary ($(echo "$filetype" | cut -d: -f2-))"
      echo ""
    fi
  fi
done

echo "======================================================="
if [ "$FOUND" -eq 0 ]; then
  echo "OK: No non-portable hardcoded paths found. Bundle looks self-contained."
  exit 0
else
  echo "WARNING: Non-portable paths found (see above)."
  echo "These will cause issues on machines without matching installations."
  exit 1
fi

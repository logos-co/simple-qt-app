#!/usr/bin/env bash
# Check for hardcoded /nix/ references in build outputs
# Usage: ./check-nix-refs.sh [path ...]
# Default path: ./result
#
# Supports: directories, .app bundles, .dmg disk images, individual binaries
# Handles nested .app bundles inside .dmg files automatically
#
# Cross-platform:
#   macOS: uses otool, hdiutil (native)
#   Linux: uses ldd, readelf, 7z for DMG extraction (install p7zip-full)

set -euo pipefail

FOUND=0
TARGETS=("${@:-./result}")
TEMP_DIRS=()
DMG_MOUNTPOINTS=()

cleanup() {
  # Detach DMGs first (before removing temp dirs, since mount points may be temp dirs)
  for mp in "${DMG_MOUNTPOINTS[@]}"; do
    if mount | grep -q "$mp"; then
      echo ""
      echo "Unmounting $mp..."
      hdiutil detach "$mp" -quiet 2>/dev/null || true
    fi
  done
  # Then clean up temp directories
  for td in "${TEMP_DIRS[@]}"; do
    if [ -d "$td" ]; then
      rm -r "$td"
    fi
  done
}
trap cleanup EXIT

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

  # 1. Check strings for /nix/ paths
  local nix_strings
  nix_strings=$(strings "$file" 2>/dev/null | grep '/nix/' || true)
  if [ -n "$nix_strings" ]; then
    print_header
    echo "[strings] Hardcoded /nix/ paths in binary data:"
    echo "$nix_strings" | sed 's/^/  /'
    FOUND=1
  fi

  # 2. Check linked libraries (otool -L / ldd)
  if command -v otool &>/dev/null; then
    local nix_libs
    nix_libs=$(otool -L "$file" 2>/dev/null | tail -n +2 | grep '/nix/' || true)
    if [ -n "$nix_libs" ]; then
      print_header
      echo "[otool -L] Linked libraries pointing to /nix/:"
      echo "$nix_libs" | sed 's/^/  /'
      FOUND=1
    fi
  elif command -v ldd &>/dev/null; then
    local nix_libs
    nix_libs=$(ldd "$file" 2>/dev/null | grep '/nix/' || true)
    if [ -n "$nix_libs" ]; then
      print_header
      echo "[ldd] Linked libraries pointing to /nix/:"
      echo "$nix_libs" | sed 's/^/  /'
      FOUND=1
    fi
  fi

  # 3. Check RPATHs
  if command -v otool &>/dev/null; then
    local nix_rpaths
    nix_rpaths=$(otool -l "$file" 2>/dev/null | grep -A2 LC_RPATH | grep '/nix/' || true)
    if [ -n "$nix_rpaths" ]; then
      print_header
      echo "[otool -l] RPATHs pointing to /nix/:"
      echo "$nix_rpaths" | sed 's/^/  /'
      FOUND=1
    fi
  elif command -v readelf &>/dev/null; then
    local nix_rpaths
    nix_rpaths=$(readelf -d "$file" 2>/dev/null | grep -E 'RPATH|RUNPATH' | grep '/nix/' || true)
    if [ -n "$nix_rpaths" ]; then
      print_header
      echo "[readelf] RPATH/RUNPATH pointing to /nix/:"
      echo "$nix_rpaths" | sed 's/^/  /'
      FOUND=1
    fi
  fi

  # 4. Check install name (macOS dylibs)
  if command -v otool &>/dev/null; then
    local nix_id
    nix_id=$(otool -D "$file" 2>/dev/null | grep '/nix/' || true)
    if [ -n "$nix_id" ]; then
      print_header
      echo "[otool -D] Install name pointing to /nix/:"
      echo "$nix_id" | sed 's/^/  /'
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
    # Use `file` to detect actual binaries (Mach-O, ELF)
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
    # macOS: mount the DMG natively to a random temp directory to avoid collisions
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
  elif command -v 7z &>/dev/null; then
    # Linux fallback: extract with 7z
    echo "Extracting DMG with 7z: $dmg ..."
    local tmpdir
    tmpdir=$(mktemp -d)
    TEMP_DIRS+=("$tmpdir")

    7z x -o"$tmpdir" "$dmg" -y >/dev/null 2>&1 || {
      echo "Error: 7z failed to extract '$dmg'"
      return 1
    }

    # 7z may extract a nested HFS filesystem image; try to extract that too
    local hfs_img
    hfs_img=$(find "$tmpdir" -maxdepth 2 -type f \( -name "*.hfs" -o -name "*.hfsx" -o -name "*[0-9].dmg" \) 2>/dev/null | head -1)
    if [ -n "$hfs_img" ]; then
      local tmpdir2
      tmpdir2=$(mktemp -d)
      TEMP_DIRS+=("$tmpdir2")
      echo "  Found inner HFS image, extracting..."
      7z x -o"$tmpdir2" "$hfs_img" -y >/dev/null 2>&1 || true
      echo "  Extracted to: $tmpdir2"
      echo ""
      scan_directory "$tmpdir2"
    else
      echo "  Extracted to: $tmpdir"
      echo ""
      scan_directory "$tmpdir"
    fi
  else
    echo "Error: Cannot open DMG files on this system."
    echo "  macOS: hdiutil is expected but not found."
    echo "  Linux: install p7zip (7z) to extract DMG files."
    echo "    Debian/Ubuntu: sudo apt install p7zip-full"
    echo "    Fedora/RHEL:   sudo dnf install p7zip p7zip-plugins"
    echo "    Arch:           sudo pacman -S p7zip"
    return 1
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
for TARGET in "${TARGETS[@]}"; do
  if [ ! -e "$TARGET" ]; then
    echo "Error: '$TARGET' does not exist."
    echo "Usage: $0 [path ...]"
    exit 1
  fi

  echo "Scanning '$TARGET' for hardcoded /nix/ references..."
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
      echo "  If this is a disk image or archive, extract/mount it first."
      echo ""
    fi
  fi
done

echo "======================================================="
if [ "$FOUND" -eq 0 ]; then
  echo "OK: No hardcoded /nix/ references found."
  exit 0
else
  echo "WARNING: Hardcoded /nix/ references were found (see above)."
  exit 1
fi

#!/usr/bin/env bash
set -uo pipefail

APP="${1:-LogosApp.app}"
APP="$(cd "$APP" && pwd)"
FW="$APP/Contents/Frameworks"

PROCESSED_FILE=$(mktemp)
trap "rm -f $PROCESSED_FILE" EXIT

# ============================================================
# Helpers
# ============================================================

# Called once per pass and cached — never called inside loops
get_macho_files() {
  find "$APP/Contents" -type f ! -type l 2>/dev/null | while read -r f; do
    file "$f" 2>/dev/null | grep -q "Mach-O" && echo "$f" || true
  done
}

copy_and_fix_dylib() {
  local nix_path="$1"
  local lib_basename
  lib_basename=$(basename "$nix_path")

  if grep -qF "$nix_path" "$PROCESSED_FILE" 2>/dev/null; then
    return 0
  fi
  echo "$nix_path" >> "$PROCESSED_FILE"

  if [ ! -f "$FW/$lib_basename" ]; then
    if [ ! -f "$nix_path" ]; then
      echo "  WARNING: $nix_path not found in Nix store, skipping"
      return 0
    fi
    echo "  Copying: $lib_basename"
    cp "$nix_path" "$FW/$lib_basename"
    chmod 644 "$FW/$lib_basename"
  fi

  install_name_tool -id "@rpath/$lib_basename" "$FW/$lib_basename" 2>/dev/null || true

  # Immediately resolve transitive Nix deps of the newly copied dylib
  while IFS= read -r dep; do
    dep_name=$(basename "$dep")
    copy_and_fix_dylib "$dep" || true
    install_name_tool -change "$dep" "@rpath/$dep_name" "$FW/$lib_basename" 2>/dev/null || true
  done < <(otool -L "$FW/$lib_basename" 2>/dev/null \
    | tail -n +2 | awk '{print $1}' | grep "^/nix/store" || true)
}

# ============================================================
# 1. Fix framework symlinks
# ============================================================
echo "=== 1. Fixing framework symlinks ==="
chmod -R u+w "$APP"

cd "$FW"
for framework in *.framework; do
  name=$(basename "$framework" .framework)

  if [ -d "$framework/Versions/Current" ] && [ ! -L "$framework/Versions/Current" ]; then
    rm -rf "$framework/Versions/Current"
    ln -s A "$framework/Versions/Current"
    echo "  Fixed: $name Versions/Current"
  fi
  if [ -d "$framework/Resources" ] && [ ! -L "$framework/Resources" ]; then
    rm -rf "$framework/Resources"
    ln -s "Versions/Current/Resources" "$framework/Resources"
    echo "  Fixed: $name Resources"
  fi
  if [ -d "$framework/Headers" ] && [ ! -L "$framework/Headers" ]; then
    rm -rf "$framework/Headers"
    ln -s "Versions/Current/Headers" "$framework/Headers"
    echo "  Fixed: $name Headers"
  fi
  if [ -f "$framework/$name" ] && [ ! -L "$framework/$name" ]; then
    rm "$framework/$name"
    ln -s "Versions/Current/$name" "$framework/$name"
    echo "  Fixed: $name top-level binary"
  fi
done
cd "$APP"

# ============================================================
# 2. Move non-dylib files out of Plugins (needed for signing)
# ============================================================
echo ""
echo "=== 2. Fixing PlugIns ==="
find "$APP/Contents/PlugIns" -type f ! -name "*.dylib" | while read -r f; do
  relpath="${f#$APP/Contents/PlugIns/}"
  targetdir="$APP/Contents/Resources/plugin-resources/$(dirname "$relpath")"
  mkdir -p "$targetdir"
  echo "  Moving: $relpath"
  mv "$f" "$targetdir/$(basename "$f")"
done || true

# ============================================================
# 3. Fix all Nix store references (loop until clean)
# ============================================================
echo ""
echo "=== 3. Fixing Nix store references ==="

pass=0
while true; do
  pass=$((pass + 1))

  if [ "$pass" -gt 10 ]; then
    echo "WARNING: Giving up after 10 passes, some references may be unfixable."
    break
  fi

  # Cache Mach-O file list ONCE per pass - reused in all loops below
  MACHO_CACHE=$(get_macho_files)

  ALL_NIX_REFS=$(echo "$MACHO_CACHE" | while read -r f; do
    otool -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}' | grep "^/nix/store" || true
  done | sort -u) || true

  if [ -z "$ALL_NIX_REFS" ]; then
    echo "  No Nix references remaining. Done!"
    break
  fi

  ref_count=$(echo "$ALL_NIX_REFS" | wc -l | tr -d ' ')
  echo ""
  echo "--- Pass $pass: found $ref_count references ---"
  echo "$ALL_NIX_REFS" | while read -r ref; do echo "  $ref"; done
  echo ""

  # Copy/fix IDs for all refs first
  while IFS= read -r nix_path; do
    lib_basename=$(basename "$nix_path")

    if echo "$nix_path" | grep -q '\.framework/'; then
      fw_relative=$(echo "$nix_path" | sed 's|.*/lib/||')
      target="$FW/$fw_relative"
      echo "--- Framework: $fw_relative ---"
      if [ -f "$target" ]; then
        chmod 644 "$target" 2>/dev/null || true
        install_name_tool -id "@rpath/$fw_relative" "$target" 2>/dev/null || true
      else
        echo "  WARNING: $target not found, skipping"
      fi
    else
      echo "--- Library: $lib_basename ---"
      copy_and_fix_dylib "$nix_path" || true
    fi
  done <<< "$ALL_NIX_REFS" || true

  echo ""
  echo "  Rewriting load commands..."

  # Rewrite all refs per file in a single install_name_tool call
  while IFS= read -r filepath; do
    file_nix_refs=$(otool -L "$filepath" 2>/dev/null \
      | tail -n +2 | awk '{print $1}' | grep "^/nix/store" || true)

    [ -z "$file_nix_refs" ] && continue

    chmod 644 "$filepath" 2>/dev/null || true

    # Build one install_name_tool call with all - change flags for this file
    cmd=(install_name_tool)
    while IFS= read -r nix_path; do
      lib_basename=$(basename "$nix_path")
      if echo "$nix_path" | grep -q '\.framework/'; then
        fw_relative=$(echo "$nix_path" | sed 's|.*/lib/||')
        replacement="@rpath/$fw_relative"
      else
        replacement="@rpath/$lib_basename"
      fi
      cmd+=(-change "$nix_path" "$replacement")
    done <<< "$file_nix_refs"

    cmd+=("$filepath")
    echo "  Rewriting: $(echo "$filepath" | sed "s|$APP/||")"
    "${cmd[@]}" 2>/dev/null || true

  done <<< "$MACHO_CACHE"

done

# ============================================================
# 4. Add missing rpaths
# ============================================================
echo ""
echo "=== 4. Adding rpaths ==="
MACHO_CACHE=$(get_macho_files)
while IFS= read -r filepath; do
  existing=$(otool -l "$filepath" 2>/dev/null \
    | grep -A2 "LC_RPATH" | grep "path " | awk '{print $2}' || true)

  if echo "$filepath" | grep -q "Contents/MacOS/"; then
    rp="@executable_path/../Frameworks"
  elif echo "$filepath" | grep -q "Contents/Frameworks/.*\.framework/"; then
    rp="@loader_path/.."
  elif echo "$filepath" | grep -q "Contents/Frameworks/"; then
    rp="@loader_path"
  elif echo "$filepath" | grep -q "Contents/PlugIns/"; then
    rp="@loader_path/../../Frameworks"
  else
    continue
  fi

  if ! echo "$existing" | grep -qF "$rp"; then
    echo "  $(echo "$filepath" | sed "s|$APP/||") -> $rp"
    chmod 644 "$filepath" 2>/dev/null || true
    install_name_tool -add_rpath "$rp" "$filepath" 2>/dev/null || true
  fi
done <<< "$MACHO_CACHE"

# ============================================================
# 5. Fix .prl files
# ============================================================
echo ""
echo "=== 5. Fixing .prl files ==="
find "$FW" -name "*.prl" -type f ! -type l | while read -r prl; do
  if grep -q "/nix/store" "$prl"; then
    echo "  $(echo "$prl" | sed "s|$APP/||")"
    sed -i '' 's|/nix/store/[^ ]*||g' "$prl"
  fi
done || true
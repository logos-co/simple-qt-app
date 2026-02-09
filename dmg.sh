#!/usr/bin/env bash

set -e

echo "Building HelloWorld DMG..."
echo ""

# Step 1: Build the app using compile.sh
echo "==> Building the application..."
./compile.sh

# Step 2: Create .app bundle structure
echo ""
echo "==> Creating .app bundle..."
APP_DIR="build/HelloWorld.app"
rm -rf "$APP_DIR"

mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Frameworks"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/PlugIns"

# Step 3: Copy the binary
echo "Copying binary..."
cp build/HelloWorld "$APP_DIR/Contents/MacOS/"
chmod +x "$APP_DIR/Contents/MacOS/HelloWorld"

# Step 4: Find Qt installation
echo "Locating Qt installation..."
QT_PATH=$(otool -L build/HelloWorld | grep QtCore | awk '{print $1}' | sed 's|/lib/QtCore.framework.*||')
if [ -z "$QT_PATH" ]; then
    echo "Error: Could not find Qt installation path"
    exit 1
fi
echo "Qt path: $QT_PATH"

# Step 5: Copy Qt frameworks
echo "Copying Qt frameworks..."
for framework in QtCore QtGui QtWidgets QtDBus; do
    if [ -d "$QT_PATH/lib/$framework.framework" ]; then
        echo "  - $framework"
        cp -R "$QT_PATH/lib/$framework.framework" "$APP_DIR/Contents/Frameworks/"
    fi
done

# Step 6: Copy Qt plugins
echo "Copying Qt plugins..."
if [ -d "$QT_PATH/plugins" ]; then
    cp -R "$QT_PATH/plugins/platforms" "$APP_DIR/Contents/PlugIns/" 2>/dev/null || true
    cp -R "$QT_PATH/plugins/styles" "$APP_DIR/Contents/PlugIns/" 2>/dev/null || true
    cp -R "$QT_PATH/plugins/imageformats" "$APP_DIR/Contents/PlugIns/" 2>/dev/null || true
fi

# Step 7: Create qt.conf
echo "Creating qt.conf..."
cat > "$APP_DIR/Contents/Resources/qt.conf" <<EOF
[Paths]
Plugins = PlugIns
EOF

# Step 8: Create Info.plist
echo "Creating Info.plist..."
sed -e "s/@VERSION@/1.0.0/g" \
    -e "s/@BUILD_NUMBER@/1/g" \
    "app/macos/Info.plist.in" > "$APP_DIR/Contents/Info.plist"

# Step 9: Create PkgInfo
echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

# Step 10: Check for macdeployqt
echo "Checking for macdeployqt..."
MACDEPLOYQT="$QT_PATH/bin/macdeployqt"

if [ -f "$MACDEPLOYQT" ]; then
    echo "Using macdeployqt for comprehensive bundling..."
    "$MACDEPLOYQT" "$APP_DIR" -always-overwrite
    echo "macdeployqt completed successfully!"
else
    echo "macdeployqt not found, using manual bundling..."
    echo "Warning: This may not catch all dependencies. Consider using 'nix build .#dmg' for production builds."
    
    # Fix install names manually
    echo "Fixing install names..."
    for framework in QtCore QtGui QtWidgets QtDBus; do
        if [ -f "$APP_DIR/Contents/Frameworks/$framework.framework/Versions/A/$framework" ]; then
            install_name_tool -id "@executable_path/../Frameworks/$framework.framework/Versions/A/$framework" \
                "$APP_DIR/Contents/Frameworks/$framework.framework/Versions/A/$framework" 2>/dev/null || true
            install_name_tool -change "$QT_PATH/lib/$framework.framework/Versions/A/$framework" \
                "@executable_path/../Frameworks/$framework.framework/Versions/A/$framework" \
                "$APP_DIR/Contents/MacOS/HelloWorld" 2>/dev/null || true
        fi
    done

    # Fix inter-framework dependencies
    for framework in QtGui QtWidgets QtDBus; do
        if [ -f "$APP_DIR/Contents/Frameworks/$framework.framework/Versions/A/$framework" ]; then
            install_name_tool -change "$QT_PATH/lib/QtCore.framework/Versions/A/QtCore" \
                "@executable_path/../Frameworks/QtCore.framework/Versions/A/QtCore" \
                "$APP_DIR/Contents/Frameworks/$framework.framework/Versions/A/$framework" 2>/dev/null || true
        fi
    done

    # QtWidgets depends on QtGui
    if [ -f "$APP_DIR/Contents/Frameworks/QtWidgets.framework/Versions/A/QtWidgets" ]; then
        install_name_tool -change "$QT_PATH/lib/QtGui.framework/Versions/A/QtGui" \
            "@executable_path/../Frameworks/QtGui.framework/Versions/A/QtGui" \
            "$APP_DIR/Contents/Frameworks/QtWidgets.framework/Versions/A/QtWidgets" 2>/dev/null || true
    fi

    # Fix plugin dependencies
    echo "Fixing plugin dependencies..."
    find "$APP_DIR/Contents/PlugIns" -name "*.dylib" -type f | while read plugin; do
        for framework in QtCore QtGui QtWidgets QtDBus; do
            install_name_tool -change "$QT_PATH/lib/$framework.framework/Versions/A/$framework" \
                "@executable_path/../Frameworks/$framework.framework/Versions/A/$framework" \
                "$plugin" 2>/dev/null || true
        done
    done

    # Add rpath
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_DIR/Contents/MacOS/HelloWorld" 2>/dev/null || true
fi

# Step 11: Codesign
echo "Codesigning..."
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || echo "Warning: Codesigning failed (continuing anyway)"

# Step 12: Create DMG staging
echo ""
echo "==> Creating DMG..."
DMG_STAGING="build/dmg_staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"

cp -R "$APP_DIR" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

# Step 13: Create DMG
DMG_NAME="HelloWorld-1.0.0.dmg"
rm -f "build/$DMG_NAME"

APP_SIZE=$(du -sm "$DMG_STAGING" | cut -f1)
DMG_SIZE=$((APP_SIZE + 20))

hdiutil create -srcfolder "$DMG_STAGING" \
    -volname "HelloWorld" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -size ${DMG_SIZE}m \
    build/temp.dmg

# Mount and unmount to finalize
MOUNT_DIR=$(mktemp -d)
hdiutil attach build/temp.dmg -mountpoint "$MOUNT_DIR" -nobrowse -quiet
hdiutil detach "$MOUNT_DIR" -quiet
rm -rf "$MOUNT_DIR"

# Convert to compressed DMG
hdiutil convert build/temp.dmg \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "build/$DMG_NAME"

rm build/temp.dmg

echo ""
echo "==> DMG created successfully!"
echo "Location: $(pwd)/build/$DMG_NAME"
echo ""
echo "You can now distribute this DMG file."

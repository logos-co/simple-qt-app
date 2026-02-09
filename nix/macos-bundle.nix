# Creates a macOS .app bundle for HelloWorld
{ pkgs, app, src }:

pkgs.stdenv.mkDerivation rec {
  pname = "HelloWorld";
  version = "1.0.0";
  
  dontUnpack = true;
  dontWrapQtApps = true;
  
  nativeBuildInputs = [ pkgs.makeWrapper ];
  buildInputs = [ pkgs.qt6.qtbase ];
  
  appSrc = src;
  
  installPhase = ''
    runHook preInstall
    
    mkdir -p "$out/HelloWorld.app/Contents/MacOS"
    mkdir -p "$out/HelloWorld.app/Contents/Frameworks"
    mkdir -p "$out/HelloWorld.app/Contents/Resources"
    mkdir -p "$out/HelloWorld.app/Contents/PlugIns"
    
    # Copy the binary (check for wrapped version first)
    if [ -f "${app}/bin/.HelloWorld-wrapped" ]; then
      cp -L "${app}/bin/.HelloWorld-wrapped" "$out/HelloWorld.app/Contents/MacOS/HelloWorld"
    else
      cp -L "${app}/bin/HelloWorld" "$out/HelloWorld.app/Contents/MacOS/"
    fi
    chmod +x "$out/HelloWorld.app/Contents/MacOS/HelloWorld"
    
    # Copy Qt frameworks
    qtbase="${pkgs.qt6.qtbase}"
    for framework in QtCore QtGui QtWidgets QtDBus; do
      if [ -d "$qtbase/lib/$framework.framework" ]; then
        cp -RL "$qtbase/lib/$framework.framework" "$out/HelloWorld.app/Contents/Frameworks/"
      fi
    done
    
    # Copy Qt plugins
    if [ -d "$qtbase/lib/qt-6/plugins" ]; then
      cp -RL "$qtbase/lib/qt-6/plugins/platforms" "$out/HelloWorld.app/Contents/PlugIns/" || true
      cp -RL "$qtbase/lib/qt-6/plugins/styles" "$out/HelloWorld.app/Contents/PlugIns/" || true
      cp -RL "$qtbase/lib/qt-6/plugins/imageformats" "$out/HelloWorld.app/Contents/PlugIns/" || true
    fi
    
    # Create qt.conf
    cat > "$out/HelloWorld.app/Contents/Resources/qt.conf" <<EOF
[Paths]
Plugins = PlugIns
EOF
    
    # Create Info.plist
    sed -e "s/@VERSION@/${version}/g" \
        -e "s/@BUILD_NUMBER@/1/g" \
        "${appSrc}/app/macos/Info.plist.in" > "$out/HelloWorld.app/Contents/Info.plist"
    
    # Create PkgInfo
    echo -n "APPL????" > "$out/HelloWorld.app/Contents/PkgInfo"
    
    # Fix install names for Qt frameworks
    for framework in QtCore QtGui QtWidgets QtDBus; do
      install_name_tool -change "$qtbase/lib/$framework.framework/Versions/A/$framework" \
        "@executable_path/../Frameworks/$framework.framework/Versions/A/$framework" \
        "$out/HelloWorld.app/Contents/MacOS/HelloWorld" 2>/dev/null || true
    done
    
    # Add rpath
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$out/HelloWorld.app/Contents/MacOS/HelloWorld" 2>/dev/null || true
    
    # Ad-hoc codesign
    /usr/bin/codesign --force --deep --sign - "$out/HelloWorld.app" 2>/dev/null || echo "Codesigning skipped (requires macOS)"
    
    # Create convenience symlink
    ln -s "HelloWorld.app/Contents/MacOS/HelloWorld" "$out/HelloWorld"
    
    runHook postInstall
  '';
  
  meta = with pkgs.lib; {
    description = "HelloWorld macOS Application Bundle";
    platforms = platforms.darwin;
  };
}

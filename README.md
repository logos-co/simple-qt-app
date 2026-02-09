# simple-qt-app

A minimal "Hello World" Qt C++ application with multiple build options.

## Structure

```
simple-qt-app/
  app/
    main.cpp              # Qt hello world (QApplication + QLabel)
    CMakeLists.txt        # CMake build config
    macos/
      Info.plist.in       # macOS bundle Info.plist template
  nix/
    app.nix               # Nix derivation to build the app
    macos-bundle.nix      # Creates macOS .app bundle
    macos-dmg.nix         # Creates DMG installer
  flake.nix               # Nix flake with app, app-bundle, dmg outputs
  compile.sh              # Shell script for local compilation
```

## Building

### Option 1: Local Build with compile.sh

Requires Qt6, CMake, and Ninja installed on your system:

```bash
./compile.sh
```

This will build the app in the `build/` directory. Run with:

```bash
./build/HelloWorld
```

### Option 1b: Local DMG Build with dmg.sh (macOS only)

Build a DMG using local tools (uses compile.sh internally):

```bash
./dmg.sh
```

This will:
1. Compile the app using `compile.sh`
2. Create a .app bundle with all necessary Qt frameworks
3. Fix library paths and codesign
4. Create a distributable DMG at `build/HelloWorld-1.0.0.dmg`

**Note:** The script will use `macdeployqt` (Qt's official bundling tool) if available, which ensures all dependencies are properly bundled. If `macdeployqt` is not found, it falls back to manual bundling which may not catch all dependencies.

**For production/distribution:** Consider using `nix build '.#dmg'` which provides more reliable dependency management and produces a truly self-contained app.

### Option 2: Nix Build

Build the app with Nix:

```bash
nix build
```

Run with:

```bash
./result/bin/HelloWorld
```

### Option 3: macOS DMG (macOS only)

Build a distributable DMG:

```bash
nix build '.#dmg'
```

The DMG will be created at `./result/HelloWorld.dmg`

You can also build just the .app bundle:

```bash
nix build '.#app-bundle'
```

## Development

Enter the Nix development shell:

```bash
nix develop
```

This provides all necessary build tools (CMake, Ninja, Qt6) in an isolated environment.

## Verifying DMG Self-Containment

To check if your .app bundle is truly self-contained (doesn't rely on system Qt), use these commands:

```bash
# Check the main binary dependencies
otool -L build/HelloWorld.app/Contents/MacOS/HelloWorld

# Check Qt framework dependencies (should show @executable_path or @rpath)
otool -L build/HelloWorld.app/Contents/Frameworks/QtWidgets.framework/Versions/A/QtWidgets

# Check plugin dependencies
otool -L build/HelloWorld.app/Contents/PlugIns/platforms/libqcocoa.dylib
```

All paths should show `@executable_path` or `@rpath` instead of absolute paths like `/usr/local/...` or `/opt/homebrew/...`.

If you see absolute paths, the app won't work on other machines without Qt installed in the same location.

**Most reliable for distribution:** Use `nix build '.#dmg'` which produces a fully self-contained bundle regardless of your local Qt installation.

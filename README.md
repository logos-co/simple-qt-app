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

#!/usr/bin/env bash

set -e

echo "Building HelloWorld Qt app..."
echo ""

# Create build directory
mkdir -p build

# Configure with CMake
echo "Configuring CMake..."
cmake -S app -B build -GNinja

# Build
echo "Building..."
cmake --build build

echo ""
echo "Build complete!"
echo "Binary location: $(pwd)/build/HelloWorld"
echo ""
echo "Run with: ./build/HelloWorld"

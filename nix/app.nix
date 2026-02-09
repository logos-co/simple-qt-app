# Builds the HelloWorld Qt application
{ pkgs, src }:

pkgs.stdenv.mkDerivation rec {
  pname = "helloworld-app";
  version = "1.0.0";
  
  inherit src;
  
  nativeBuildInputs = [ 
    pkgs.cmake 
    pkgs.ninja 
    pkgs.pkg-config
    pkgs.qt6.wrapQtAppsHook
  ];
  
  buildInputs = [ 
    pkgs.qt6.qtbase 
  ];
  
  meta = with pkgs.lib; {
    description = "HelloWorld - Simple Qt application";
    platforms = platforms.unix;
  };
  
  configurePhase = ''
    runHook preConfigure
    
    echo "Configuring HelloWorld app..."
    cmake -S app -B build \
      -GNinja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0
    
    runHook postConfigure
  '';
  
  buildPhase = ''
    runHook preBuild
    
    cmake --build build
    echo "HelloWorld app built successfully!"
    
    runHook postBuild
  '';
  
  installPhase = ''
    runHook preInstall
    
    # Create output directories
    mkdir -p $out/bin
    
    # Install our app binary
    if [ -f "build/HelloWorld" ]; then
      cp build/HelloWorld "$out/bin/HelloWorld"
      echo "Installed HelloWorld binary"
    fi
    
    runHook postInstall
  '';
}

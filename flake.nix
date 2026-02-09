{
  description = "HelloWorld - Simple Qt application";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f {
        pkgs = import nixpkgs { inherit system; };
      });
    in
    {
      packages = forAllSystems ({ pkgs }: 
        let
          src = ./.;
          
          # App package
          app = import ./nix/app.nix { 
            inherit pkgs src;
          };
          
          # macOS distribution packages (only for Darwin)
          appBundle = if pkgs.stdenv.isDarwin then
            import ./nix/macos-bundle.nix {
              inherit pkgs src;
              app = app;
            }
          else null;
          
          dmg = if pkgs.stdenv.isDarwin then
            import ./nix/macos-dmg.nix {
              inherit pkgs;
              appBundle = appBundle;
            }
          else null;
        in
        {
          # Main app output
          app = app;
          
          # Default package
          default = app;
        } // (if pkgs.stdenv.isDarwin then {
          # macOS distribution outputs
          app-bundle = appBundle;
          inherit dmg;
        } else {})
      );

      devShells = forAllSystems ({ pkgs }: {
        default = pkgs.mkShell {
          nativeBuildInputs = [
            pkgs.cmake
            pkgs.ninja
            pkgs.pkg-config
          ];
          buildInputs = [
            pkgs.qt6.qtbase
          ];
          
          shellHook = ''
            echo "HelloWorld Qt development environment"
            echo ""
            echo "Build commands:"
            echo "  ./compile.sh          - Build with local tools"
            echo "  nix build             - Build with Nix"
            echo "  nix build '.#dmg'     - Build macOS DMG (macOS only)"
          '';
        };
      });
    };
}

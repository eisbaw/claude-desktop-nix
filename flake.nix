{
  description = "Claude Desktop for Linux - Nix flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Map Nix system to the architecture used by build.sh
        arch = if system == "x86_64-linux" then "amd64"
               else if system == "aarch64-linux" then "arm64"
               else throw "Unsupported system: ${system}";

        buildDeps = with pkgs; [
          p7zip
          wget
          icoutils  # provides wrestool and icotool
          imagemagick  # provides convert
          dpkg
          nodejs_20
          electron
          nodePackages.asar
          xorg.lndir
        ];

      in
      {
        packages = {
          default = pkgs.stdenv.mkDerivation {
            pname = "claude-desktop";
            version = "0.7.5";  # This will be detected from the installer

            src = ./.;

            nativeBuildInputs = buildDeps;

            buildPhase = ''
              runHook preBuild

              # Create a temporary home directory
              export HOME=$TMPDIR

              # Run the build script
              bash build.sh --build deb --clean no

              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall

              mkdir -p $out

              # Find the generated .deb file
              DEB_FILE=$(find . -maxdepth 1 -name "claude-desktop_*.deb" | head -n 1)

              if [ -n "$DEB_FILE" ]; then
                # Extract the .deb package
                dpkg-deb -x "$DEB_FILE" $out

                # Fix paths in the launcher script if needed
                if [ -f $out/usr/bin/claude-desktop ]; then
                  substituteInPlace $out/usr/bin/claude-desktop \
                    --replace /usr/share $out/usr/share || true
                fi
              else
                echo "ERROR: No .deb file found"
                exit 1
              fi

              runHook postInstall
            '';

            meta = with pkgs.lib; {
              description = "Claude Desktop for Linux";
              homepage = "https://github.com/aaddrick/claude-desktop-debian";
              license = with licenses; [ mit asl20 ];
              platforms = [ "x86_64-linux" "aarch64-linux" ];
            };
          };
        };

        devShells.default = pkgs.mkShell {
          buildInputs = buildDeps ++ (with pkgs; [
            git
            xvfb-run
            scrot  # For screenshots
            imagemagick  # For image conversion
          ]);

          shellHook = ''
            echo "Claude Desktop Linux Build Environment"
            echo "======================================"
            echo "Available commands:"
            echo "  ./build.sh              - Build .deb package"
            echo "  ./build.sh --build appimage - Build AppImage"
            echo ""
            echo "For headless testing:"
            echo "  xvfb-run -a ./your-app"
            echo ""
            echo "Dependencies:"
            ${pkgs.lib.concatMapStringsSep "\n" (dep: "echo \"  ✓ ${dep.pname or dep.name}\"") buildDeps}
          '';
        };
      }
    );
}

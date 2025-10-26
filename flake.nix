{
  description = "Claude Desktop for Linux - Nix build";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Determine architecture-specific values
        archInfo = if system == "x86_64-linux" then {
          arch = "x64";
          debArch = "amd64";
          url = "https://storage.googleapis.com/osprey-downloads-c02f6a0d-347c-492b-a752-3e0651722e97/nest-win-x64/Claude-Setup-x64.exe";
          # You'll need to update this hash after first build attempt
          sha256 = pkgs.lib.fakeSha256;
        } else {
          arch = "arm64";
          debArch = "arm64";
          url = "https://storage.googleapis.com/osprey-downloads-c02f6a0d-347c-492b-a752-3e0651722e97/nest-win-arm64/Claude-Setup-arm64.exe";
          # You'll need to update this hash after first build attempt
          sha256 = pkgs.lib.fakeSha256;
        };

        claude-desktop = pkgs.stdenv.mkDerivation rec {
          pname = "claude-desktop";
          version = "0.7.5"; # This will be detected from the nupkg filename

          # Download the Windows installer
          src = pkgs.fetchurl {
            url = archInfo.url;
            sha256 = archInfo.sha256;
          };

          nativeBuildInputs = with pkgs; [
            p7zip
            icoutils
            imagemagick
            nodejs_20
            electron
            nodePackages.asar
          ];

          buildInputs = with pkgs; [
            electron
          ];

          unpackPhase = ''
            runHook preUnpack

            echo "Extracting Claude installer..."
            7z x $src -o./claude-extract

            cd claude-extract
            # Find and extract the nupkg file
            NUPKG=$(find . -maxdepth 1 -name "AnthropicClaude-*.nupkg" | head -1)
            if [ -z "$NUPKG" ]; then
              echo "Error: Could not find AnthropicClaude nupkg file"
              exit 1
            fi

            echo "Found nupkg: $NUPKG"

            # Extract version from filename
            VERSION=$(echo "$NUPKG" | grep -oP 'AnthropicClaude-\K[0-9]+\.[0-9]+\.[0-9]+(?=-full|-arm64-full)')
            echo "Detected version: $VERSION"

            7z x "$NUPKG"

            cd ..

            runHook postUnpack
          '';

          buildPhase = ''
            runHook preBuild

            cd claude-extract

            # Extract icons
            echo "Extracting icons..."
            wrestool -x -t 14 lib/net45/claude.exe -o claude.ico
            icotool -x claude.ico

            # Prepare app.asar directory
            mkdir -p app-staging
            cp lib/net45/resources/app.asar app-staging/
            cp -r lib/net45/resources/app.asar.unpacked app-staging/

            cd app-staging

            # Extract asar
            asar extract app.asar app.asar.contents

            # Create stub native module
            cat > app.asar.contents/node_modules/claude-native/index.js << 'EOF'
// Stub implementation of claude-native using KeyboardKey enum values
const KeyboardKey = { Backspace: 43, Tab: 280, Enter: 261, Shift: 272, Control: 61, Alt: 40, CapsLock: 56, Escape: 85, Space: 276, PageUp: 251, PageDown: 250, End: 83, Home: 154, LeftArrow: 175, UpArrow: 282, RightArrow: 262, DownArrow: 81, Delete: 79, Meta: 187 };
Object.freeze(KeyboardKey);
module.exports = { getWindowsVersion: () => "10.0.0", setWindowEffect: () => {}, removeWindowEffect: () => {}, getIsMaximized: () => false, flashFrame: () => {}, clearFlashFrame: () => {}, showNotification: () => {}, setProgressBar: () => {}, clearProgressBar: () => {}, setOverlayIcon: () => {}, clearOverlayIcon: () => {}, KeyboardKey };
EOF

            # Copy resources
            mkdir -p app.asar.contents/resources
            mkdir -p app.asar.contents/resources/i18n
            cp ../lib/net45/resources/Tray* app.asar.contents/resources/
            cp ../lib/net45/resources/*-*.json app.asar.contents/resources/i18n/

            # Fix title bar for Linux
            echo "Fixing title bar for Linux..."
            SEARCH_BASE="app.asar.contents/.vite/renderer/main_window/assets"
            TARGET_PATTERN="MainWindowPage-*.js"

            TARGET_FILE=$(find "$SEARCH_BASE" -type f -name "$TARGET_PATTERN" | head -1)
            if [ -z "$TARGET_FILE" ]; then
              echo "Error: Could not find MainWindowPage file"
              exit 1
            fi

            echo "Found target file: $TARGET_FILE"
            sed -i -E 's/if\(!([a-zA-Z]+)[[:space:]]*&&[[:space:]]*([a-zA-Z]+)\)/if(\1 \&\& \2)/g' "$TARGET_FILE"

            # Repack asar
            asar pack app.asar.contents app.asar

            # Create unpacked stub
            mkdir -p app.asar.unpacked/node_modules/claude-native
            cat > app.asar.unpacked/node_modules/claude-native/index.js << 'EOF'
// Stub implementation of claude-native using KeyboardKey enum values
const KeyboardKey = { Backspace: 43, Tab: 280, Enter: 261, Shift: 272, Control: 61, Alt: 40, CapsLock: 56, Escape: 85, Space: 276, PageUp: 251, PageDown: 250, End: 83, Home: 154, LeftArrow: 175, UpArrow: 282, RightArrow: 262, DownArrow: 81, Delete: 79, Meta: 187 };
Object.freeze(KeyboardKey);
module.exports = { getWindowsVersion: () => "10.0.0", setWindowEffect: () => {}, removeWindowEffect: () => {}, getIsMaximized: () => false, flashFrame: () => {}, clearFlashFrame: () => {}, showNotification: () => {}, setProgressBar: () => {}, clearProgressBar: () => {}, setOverlayIcon: () => {}, clearOverlayIcon: () => {}, KeyboardKey };
EOF

            cd ../..

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            mkdir -p $out/lib/claude-desktop
            mkdir -p $out/bin
            mkdir -p $out/share/applications
            mkdir -p $out/share/icons/hicolor/{16x16,24x24,32x32,48x48,64x64,256x256}/apps

            # Install application files
            cp claude-extract/app-staging/app.asar $out/lib/claude-desktop/
            cp -r claude-extract/app-staging/app.asar.unpacked $out/lib/claude-desktop/

            # Install icons
            declare -A icon_files=(
              ["16"]="claude_13_16x16x32.png"
              ["24"]="claude_11_24x24x32.png"
              ["32"]="claude_10_32x32x32.png"
              ["48"]="claude_8_48x48x32.png"
              ["64"]="claude_7_64x64x32.png"
              ["256"]="claude_6_256x256x32.png"
            )

            for size in 16 24 32 48 64 256; do
              icon_file="claude-extract/''${icon_files[$size]}"
              if [ -f "$icon_file" ]; then
                cp "$icon_file" $out/share/icons/hicolor/''${size}x''${size}/apps/claude-desktop.png
              fi
            done

            # Create launcher script
            cat > $out/bin/claude-desktop << 'EOF'
#!/usr/bin/env bash
LOG_FILE="$HOME/claude-desktop-launcher.log"
echo "--- Claude Desktop Launcher Start ---" >> "$LOG_FILE"
echo "Timestamp: $(date)" >> "$LOG_FILE"
echo "Arguments: $@" >> "$LOG_FILE"

export ELECTRON_FORCE_IS_PACKAGED=true

# Detect if Wayland is running
IS_WAYLAND=false
if [ ! -z "$WAYLAND_DISPLAY" ]; then
  IS_WAYLAND=true
  echo "Wayland detected" >> "$LOG_FILE"
fi

# Electron path - use Nix's electron
ELECTRON_EXEC="@electron@/bin/electron"
APP_PATH="@out@/lib/claude-desktop/app.asar"
ELECTRON_ARGS=("$APP_PATH")

# Add compatibility flags for Wayland
if [ "$IS_WAYLAND" = true ]; then
  echo "Adding Wayland compatibility flags" >> "$LOG_FILE"
  ELECTRON_ARGS+=("--no-sandbox")
  ELECTRON_ARGS+=("--enable-features=UseOzonePlatform,WaylandWindowDecorations,GlobalShortcutsPortal")
  ELECTRON_ARGS+=("--ozone-platform=wayland")
  ELECTRON_ARGS+=("--enable-wayland-ime")
  ELECTRON_ARGS+=("--wayland-text-input-version=3")
fi

# Change to application directory
APP_DIR="@out@/lib/claude-desktop"
cd "$APP_DIR" || { echo "Failed to cd to $APP_DIR" >> "$LOG_FILE"; exit 1; }

# Execute Electron
echo "Executing: $ELECTRON_EXEC ''${ELECTRON_ARGS[@]} $@" >> "$LOG_FILE"
"$ELECTRON_EXEC" "''${ELECTRON_ARGS[@]}" "$@" >> "$LOG_FILE" 2>&1
EXIT_CODE=$?
echo "Electron exited with code: $EXIT_CODE" >> "$LOG_FILE"
echo "--- Claude Desktop Launcher End ---" >> "$LOG_FILE"
exit $EXIT_CODE
EOF

            chmod +x $out/bin/claude-desktop

            # Substitute paths in launcher
            substituteInPlace $out/bin/claude-desktop \
              --replace "@electron@" "${pkgs.electron}" \
              --replace "@out@" "$out"

            # Create desktop entry
            cat > $out/share/applications/claude-desktop.desktop << EOF
[Desktop Entry]
Name=Claude
Exec=$out/bin/claude-desktop %u
Icon=claude-desktop
Type=Application
Terminal=false
Categories=Office;Utility;Network;
MimeType=x-scheme-handler/claude;
StartupWMClass=Claude
EOF

            runHook postInstall
          '';

          meta = with pkgs.lib; {
            description = "Claude Desktop for Linux";
            homepage = "https://github.com/aaddrick/claude-desktop-debian";
            license = licenses.unfree;
            platforms = [ "x86_64-linux" "aarch64-linux" ];
            maintainers = [ ];
          };
        };

      in
      {
        packages.default = claude-desktop;
        packages.claude-desktop = claude-desktop;

        apps.default = {
          type = "app";
          program = "${claude-desktop}/bin/claude-desktop";
        };
      }
    );
}

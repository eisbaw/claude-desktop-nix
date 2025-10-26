#!/bin/bash
set -euo pipefail

# --- Architecture Detection ---
echo -e "\033[1;36m--- Architecture Detection ---\033[0m"
echo "⚙️ Detecting system architecture..."
HOST_ARCH=$(dpkg --print-architecture)
echo "Detected host architecture: $HOST_ARCH"
cat /etc/os-release && uname -m && dpkg --print-architecture

# Set variables based on detected architecture
if [ "$HOST_ARCH" = "amd64" ]; then
    # Updated URL from claude.ai/download page (2025)
    CLAUDE_DOWNLOAD_URL="https://claude.ai/api/desktop/win32/x64/exe/latest/redirect"
    ARCHITECTURE="amd64"
    CLAUDE_EXE_FILENAME="Claude-Setup-x64.exe"
    echo "Configured for amd64 build."
elif [ "$HOST_ARCH" = "arm64" ]; then
    # Updated URL from claude.ai/download page (2025)
    CLAUDE_DOWNLOAD_URL="https://claude.ai/api/desktop/win32/arm64/exe/latest/redirect"
    ARCHITECTURE="arm64"
    CLAUDE_EXE_FILENAME="Claude-Setup-arm64.exe"
    echo "Configured for arm64 build."
else
    echo "❌ Unsupported architecture: $HOST_ARCH. This script currently supports amd64 and arm64."
    exit 1
fi
echo "Target Architecture (detected): $ARCHITECTURE" # Renamed echo
echo -e "\033[1;36m--- End Architecture Detection ---\033[0m"


if [ ! -f "/etc/debian_version" ]; then
    echo "❌ This script requires a Debian-based Linux distribution"
    exit 1
fi

if [ "$EUID" -eq 0 ]; then
   echo "❌ This script should not be run using sudo or as the root user."
   echo "   It will prompt for sudo password when needed for specific actions."
   echo "   Please run as a normal user."
   exit 1
fi

ORIGINAL_USER=$(whoami)
ORIGINAL_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)
if [ -z "$ORIGINAL_HOME" ]; then
    echo "❌ Could not determine home directory for user $ORIGINAL_USER."
    exit 1
fi
echo "Running as user: $ORIGINAL_USER (Home: $ORIGINAL_HOME)"

# Check for NVM and source it if found - this may provide a Node.js 20+ version
if [ -d "$ORIGINAL_HOME/.nvm" ]; then
    echo "Found NVM installation for user $ORIGINAL_USER, checking for Node.js 20+..."
    export NVM_DIR="$ORIGINAL_HOME/.nvm"
    if [ -s "$NVM_DIR/nvm.sh" ]; then
        # Source NVM script to set up NVM environment variables temporarily
        # shellcheck disable=SC1091
        \. "$NVM_DIR/nvm.sh" # This loads nvm
        # Initialize and find the path to the currently active or default Node version's bin directory
        NODE_BIN_PATH=""
        NODE_BIN_PATH=$(nvm which current | xargs dirname 2>/dev/null || find "$NVM_DIR/versions/node" -maxdepth 2 -type d -name 'bin' | sort -V | tail -n 1)

        if [ -n "$NODE_BIN_PATH" ] && [ -d "$NODE_BIN_PATH" ]; then
            echo "Adding NVM Node bin path to PATH: $NODE_BIN_PATH"
            export PATH="$NODE_BIN_PATH:$PATH"
        else
            echo "Warning: Could not determine NVM Node bin path."
        fi
    else
        echo "Warning: nvm.sh script not found or not sourceable."
    fi
fi # End of if [ -d "$ORIGINAL_HOME/.nvm" ] check


echo "System Information:"
echo "Distribution: $(grep "PRETTY_NAME" /etc/os-release | cut -d'"' -f2)"
echo "Debian version: $(cat /etc/debian_version)"
echo "Target Architecture: $ARCHITECTURE" 
PACKAGE_NAME="claude-desktop"
MAINTAINER="Claude Desktop Linux Maintainers"
DESCRIPTION="Claude Desktop for Linux"
PROJECT_ROOT="$(pwd)" WORK_DIR="$PROJECT_ROOT/build" APP_STAGING_DIR="$WORK_DIR/electron-app" VERSION="" 
echo -e "\033[1;36m--- Argument Parsing ---\033[0m"
BUILD_FORMAT="deb"    CLEANUP_ACTION="yes"  TEST_FLAGS_MODE=false
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -b|--build)
        if [[ -z "$2" || "$2" == -* ]]; then              echo "❌ Error: Argument for $1 is missing" >&2; exit 1
        fi
        BUILD_FORMAT="$2"
        shift 2 ;; # Shift past flag and value
        -c|--clean)
        if [[ -z "$2" || "$2" == -* ]]; then              echo "❌ Error: Argument for $1 is missing" >&2; exit 1
        fi
        CLEANUP_ACTION="$2"
        shift 2 ;; # Shift past flag and value
        --test-flags)
        TEST_FLAGS_MODE=true
        shift # past argument
        ;;
        -h|--help)
        echo "Usage: $0 [--build deb|appimage] [--clean yes|no] [--test-flags]"
        echo "  --build: Specify the build format (deb or appimage). Default: deb"
        echo "  --clean: Specify whether to clean intermediate build files (yes or no). Default: yes"
        echo "  --test-flags: Parse flags, print results, and exit without building."
        exit 0
        ;;
        *)            echo "❌ Unknown option: $1" >&2
        echo "Use -h or --help for usage information." >&2
        exit 1
        ;;
    esac
done

# Validate arguments
BUILD_FORMAT=$(echo "$BUILD_FORMAT" | tr '[:upper:]' '[:lower:]') CLEANUP_ACTION=$(echo "$CLEANUP_ACTION" | tr '[:upper:]' '[:lower:]')
if [[ "$BUILD_FORMAT" != "deb" && "$BUILD_FORMAT" != "appimage" ]]; then
    echo "❌ Invalid build format specified: '$BUILD_FORMAT'. Must be 'deb' or 'appimage'." >&2
    exit 1
fi
if [[ "$CLEANUP_ACTION" != "yes" && "$CLEANUP_ACTION" != "no" ]]; then
    echo "❌ Invalid cleanup option specified: '$CLEANUP_ACTION'. Must be 'yes' or 'no'." >&2
    exit 1
fi

echo "Selected build format: $BUILD_FORMAT"
echo "Cleanup intermediate files: $CLEANUP_ACTION"

PERFORM_CLEANUP=false
if [ "$CLEANUP_ACTION" = "yes" ]; then
    PERFORM_CLEANUP=true
fi
echo -e "\033[1;36m--- End Argument Parsing ---\033[0m"

# Exit early if --test-flags mode is enabled
if [ "$TEST_FLAGS_MODE" = true ]; then
    echo "--- Test Flags Mode Enabled ---"
    # Target Architecture is implicitly detected now
    echo "Build Format: $BUILD_FORMAT"
    echo "Clean Action: $CLEANUP_ACTION"
    echo "Exiting without build."
    exit 0
fi


check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo "❌ $1 not found"
        return 1
    else
        echo "✓ $1 found"
        return 0
    fi
}

echo "Checking dependencies..."
DEPS_TO_INSTALL=""
COMMON_DEPS="p7zip wget wrestool icotool convert"
DEB_DEPS="dpkg-deb"
APPIMAGE_DEPS="" 
ALL_DEPS_TO_CHECK="$COMMON_DEPS"
if [ "$BUILD_FORMAT" = "deb" ]; then
    ALL_DEPS_TO_CHECK="$ALL_DEPS_TO_CHECK $DEB_DEPS"
elif [ "$BUILD_FORMAT" = "appimage" ]; then
    ALL_DEPS_TO_CHECK="$ALL_DEPS_TO_CHECK $APPIMAGE_DEPS"
fi

for cmd in $ALL_DEPS_TO_CHECK; do
    if ! check_command "$cmd"; then
        case "$cmd" in
            "p7zip") DEPS_TO_INSTALL="$DEPS_TO_INSTALL p7zip-full" ;;
            "wget") DEPS_TO_INSTALL="$DEPS_TO_INSTALL wget" ;;
            "wrestool"|"icotool") DEPS_TO_INSTALL="$DEPS_TO_INSTALL icoutils" ;;
            "convert") DEPS_TO_INSTALL="$DEPS_TO_INSTALL imagemagick" ;;
            "dpkg-deb") DEPS_TO_INSTALL="$DEPS_TO_INSTALL dpkg-dev" ;;
        esac
    fi
done

if [ -n "$DEPS_TO_INSTALL" ]; then
    echo "System dependencies needed: $DEPS_TO_INSTALL"
    echo "Attempting to install using sudo..."
        if ! sudo -v; then
        echo "❌ Failed to validate sudo credentials. Please ensure you can run sudo."
        exit 1
    fi
        if ! sudo apt update; then
        echo "❌ Failed to run 'sudo apt update'."
        exit 1
    fi
    # Here on purpose no "" to expand the 'list', thus
    # shellcheck disable=SC2086
    if ! sudo apt install -y $DEPS_TO_INSTALL; then
         echo "❌ Failed to install dependencies using 'sudo apt install'."
         exit 1
    fi
    echo "✓ System dependencies installed successfully via sudo."
fi

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
mkdir -p "$APP_STAGING_DIR"

echo -e "\033[1;36m--- Node.js Setup ---\033[0m"
echo "Checking Node.js version..."
NODE_VERSION_OK=false
if command -v node &> /dev/null; then
    NODE_VERSION=$(node --version | cut -d'v' -f2)
    NODE_MAJOR=$(echo "$NODE_VERSION" | cut -d'.' -f1)
    echo "System Node.js version: v$NODE_VERSION"
    
    if [ "$NODE_MAJOR" -ge 20 ]; then
        echo "✓ System Node.js version is adequate (v$NODE_VERSION)"
        NODE_VERSION_OK=true
    else
        echo "⚠️ System Node.js version is too old (v$NODE_VERSION). Need v20+"
    fi
else
    echo "⚠️ Node.js not found in system"
fi

# If system Node.js is not adequate, install a local copy
if [ "$NODE_VERSION_OK" = false ]; then
    echo "Installing Node.js v20 locally in build directory..."
    
    # Determine Node.js download URL based on architecture
    if [ "$ARCHITECTURE" = "amd64" ]; then
        NODE_ARCH="x64"
    elif [ "$ARCHITECTURE" = "arm64" ]; then
        NODE_ARCH="arm64"
    else
        echo "❌ Unsupported architecture for Node.js: $ARCHITECTURE"
        exit 1
    fi
    
    NODE_VERSION_TO_INSTALL="20.18.1"
    NODE_TARBALL="node-v${NODE_VERSION_TO_INSTALL}-linux-${NODE_ARCH}.tar.xz"
    NODE_URL="https://nodejs.org/dist/v${NODE_VERSION_TO_INSTALL}/${NODE_TARBALL}"
    NODE_INSTALL_DIR="$WORK_DIR/node"
    
    echo "Downloading Node.js v${NODE_VERSION_TO_INSTALL} for ${NODE_ARCH}..."
    cd "$WORK_DIR"
    if ! wget -O "$NODE_TARBALL" "$NODE_URL"; then
        echo "❌ Failed to download Node.js from $NODE_URL"
        cd "$PROJECT_ROOT"
        exit 1
    fi
    
    echo "Extracting Node.js..."
    if ! tar -xf "$NODE_TARBALL"; then
        echo "❌ Failed to extract Node.js tarball"
        cd "$PROJECT_ROOT"
        exit 1
    fi
    
    # Move extracted files to a consistent location
    mv "node-v${NODE_VERSION_TO_INSTALL}-linux-${NODE_ARCH}" "$NODE_INSTALL_DIR"
    
    # Add local Node.js to PATH for this script
    export PATH="$NODE_INSTALL_DIR/bin:$PATH"
    
    # Verify local Node.js installation
    if command -v node &> /dev/null; then
        LOCAL_NODE_VERSION=$(node --version)
        echo "✓ Local Node.js installed successfully: $LOCAL_NODE_VERSION"
    else
        echo "❌ Failed to install local Node.js"
        cd "$PROJECT_ROOT"
        exit 1
    fi
    
    # Clean up tarball
    rm -f "$NODE_TARBALL"
    
    cd "$PROJECT_ROOT"
fi
echo -e "\033[1;36m--- End Node.js Setup ---\033[0m" 
echo -e "\033[1;36m--- Electron & Asar Handling ---\033[0m"
CHOSEN_ELECTRON_MODULE_PATH="" ASAR_EXEC=""

echo "Ensuring local Electron and Asar installation in $WORK_DIR..."
cd "$WORK_DIR"
if [ ! -f "package.json" ]; then
    echo "Creating temporary package.json in $WORK_DIR for local install..."
    echo '{"name":"claude-desktop-build","version":"0.0.1","private":true}' > package.json
fi

ELECTRON_DIST_PATH="$WORK_DIR/node_modules/electron/dist"
ASAR_BIN_PATH="$WORK_DIR/node_modules/.bin/asar"

INSTALL_NEEDED=false
if [ ! -d "$ELECTRON_DIST_PATH" ]; then
    echo "Electron distribution not found."
    INSTALL_NEEDED=true
fi
if [ ! -f "$ASAR_BIN_PATH" ]; then
    echo "Asar binary not found."
    INSTALL_NEEDED=true
fi

if [ "$INSTALL_NEEDED" = true ]; then
    echo "Installing Electron and Asar locally into $WORK_DIR..."
    # Check if USE_NIX environment variable is set to skip npm
    if [ "$USE_NIX" = "1" ]; then
        echo "USE_NIX=1 set, skipping npm and using Nix electron/asar..."
        NPM_FAILED=true
    else
        # Try npm install first, but fall back to Nix if available
        NPM_FAILED=false
        if ! npm install --no-save electron @electron/asar 2>&1 | tee /tmp/npm-install.log; then
            NPM_FAILED=true
        fi
    fi

    if [ "$NPM_FAILED" = "true" ]; then
        if [ "$USE_NIX" != "1" ]; then
            echo "⚠️  npm install failed, checking for Nix electron/asar..."
        fi
        # Check if we have Nix electron and asar
        NIX_ELECTRON=$(ls -d /nix/store/*electron-unwrapped-* 2>/dev/null | grep -v ".drv" | head -1)
        NIX_ASAR=$(find /nix/store -path "*/bin/asar" -type f 2>/dev/null | head -1)

        if [ -n "$NIX_ELECTRON" ] && [ -n "$NIX_ASAR" ]; then
            echo "✓ Found Nix electron and asar, using them instead..."
            mkdir -p "$WORK_DIR/node_modules/electron/dist"
            mkdir -p "$WORK_DIR/node_modules/.bin"
            # Copy electron files from Nix store (can't symlink - will need to write to it later)
            echo "Copying Nix electron files (this may take a moment)..."
            cp -r "$NIX_ELECTRON"/* "$WORK_DIR/node_modules/electron/dist/"
            ln -sf "$NIX_ASAR" "$WORK_DIR/node_modules/.bin/asar"
            echo "✓ Copied Nix electron and linked asar"
        else
            echo "❌ Failed to install Electron and/or Asar locally and Nix fallback not available."
            cd "$PROJECT_ROOT"
            exit 1
        fi
    fi
    echo "✓ Electron and Asar installation command finished."
else
    echo "✓ Local Electron distribution and Asar binary already present."
fi

if [ -d "$ELECTRON_DIST_PATH" ]; then
    echo "✓ Found Electron distribution directory at $ELECTRON_DIST_PATH."
    CHOSEN_ELECTRON_MODULE_PATH="$(realpath "$WORK_DIR/node_modules/electron")"
    echo "✓ Setting Electron module path for copying to $CHOSEN_ELECTRON_MODULE_PATH."
else
    echo "❌ Failed to find Electron distribution directory at '$ELECTRON_DIST_PATH' after installation attempt."
    echo "   Cannot proceed without the Electron distribution files."
    cd "$PROJECT_ROOT"     exit 1
fi

if [ -f "$ASAR_BIN_PATH" ]; then
    ASAR_EXEC="$(realpath "$ASAR_BIN_PATH")"
    echo "✓ Found local Asar binary at $ASAR_EXEC."
else
    echo "❌ Failed to find Asar binary at '$ASAR_BIN_PATH' after installation attempt."
    cd "$PROJECT_ROOT"
    exit 1
fi

cd "$PROJECT_ROOT" 
if [ -z "$CHOSEN_ELECTRON_MODULE_PATH" ] || [ ! -d "$CHOSEN_ELECTRON_MODULE_PATH" ]; then
     echo "❌ Critical error: Could not resolve a valid Electron module path to copy."
     exit 1
fi
echo "Using Electron module path: $CHOSEN_ELECTRON_MODULE_PATH"
echo "Using asar executable: $ASAR_EXEC"


echo -e "\033[1;36m--- Download the latest Claude executable ---\033[0m"
CLAUDE_EXE_PATH="$WORK_DIR/$CLAUDE_EXE_FILENAME"

# Check for local installer first
LOCAL_INSTALLER="$PROJECT_ROOT/installers/$CLAUDE_EXE_FILENAME"
if [ -f "$LOCAL_INSTALLER" ]; then
    echo "✓ Using local installer: $LOCAL_INSTALLER"
    cp "$LOCAL_INSTALLER" "$CLAUDE_EXE_PATH"
    echo "✓ Copied local installer to build directory"
else
    echo "📥 Downloading Claude Desktop installer for $ARCHITECTURE..."
    # Use proper user agent for claude.ai API endpoint
    if ! wget --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
             -O "$CLAUDE_EXE_PATH" "$CLAUDE_DOWNLOAD_URL"; then
        echo "❌ Failed to download Claude Desktop installer from $CLAUDE_DOWNLOAD_URL"
        exit 1
    fi
    echo "✓ Download complete: $CLAUDE_EXE_FILENAME"
fi

echo "📦 Extracting resources from $CLAUDE_EXE_FILENAME into separate directory..."
CLAUDE_EXTRACT_DIR="$WORK_DIR/claude-extract"
mkdir -p "$CLAUDE_EXTRACT_DIR"
if ! 7z x -y "$CLAUDE_EXE_PATH" -o"$CLAUDE_EXTRACT_DIR"; then     echo "❌ Failed to extract installer"
    cd "$PROJECT_ROOT" && exit 1
fi

cd "$CLAUDE_EXTRACT_DIR" # Change into the extract dir to find files
NUPKG_PATH_RELATIVE=$(find . -maxdepth 1 -name "AnthropicClaude-*.nupkg" | head -1)
if [ -z "$NUPKG_PATH_RELATIVE" ]; then
    echo "❌ Could not find AnthropicClaude nupkg file in $CLAUDE_EXTRACT_DIR"
    cd "$PROJECT_ROOT" && exit 1
fi
NUPKG_PATH="$CLAUDE_EXTRACT_DIR/$NUPKG_PATH_RELATIVE" echo "Found nupkg: $NUPKG_PATH_RELATIVE (in $CLAUDE_EXTRACT_DIR)"

VERSION=$(echo "$NUPKG_PATH_RELATIVE" | LC_ALL=C grep -oP 'AnthropicClaude-\K[0-9]+\.[0-9]+\.[0-9]+(?=-full|-arm64-full)')
if [ -z "$VERSION" ]; then
    echo "❌ Could not extract version from nupkg filename: $NUPKG_PATH_RELATIVE"
    cd "$PROJECT_ROOT" && exit 1
fi
echo "✓ Detected Claude version: $VERSION"

if ! 7z x -y "$NUPKG_PATH_RELATIVE"; then     echo "❌ Failed to extract nupkg"
    cd "$PROJECT_ROOT" && exit 1
fi
echo "✓ Resources extracted from nupkg"

EXE_RELATIVE_PATH="lib/net45/claude.exe" # Check if this path is correct for arm64 too
if [ ! -f "$EXE_RELATIVE_PATH" ]; then
    echo "❌ Cannot find claude.exe at expected path within extraction dir: $CLAUDE_EXTRACT_DIR/$EXE_RELATIVE_PATH"
    cd "$PROJECT_ROOT" && exit 1
fi
echo "🎨 Processing icons from $EXE_RELATIVE_PATH..."
if ! wrestool -x -t 14 "$EXE_RELATIVE_PATH" -o claude.ico; then     echo "❌ Failed to extract icons from exe"
    cd "$PROJECT_ROOT" && exit 1
fi

if ! icotool -x claude.ico; then     echo "❌ Failed to convert icons"
    cd "$PROJECT_ROOT" && exit 1
fi
cp claude_*.png "$WORK_DIR/"
echo "✓ Icons processed and copied to $WORK_DIR"

echo "⚙️ Processing app.asar..."
cp "$CLAUDE_EXTRACT_DIR/lib/net45/resources/app.asar" "$APP_STAGING_DIR/"
cp -a "$CLAUDE_EXTRACT_DIR/lib/net45/resources/app.asar.unpacked" "$APP_STAGING_DIR/" 
cd "$APP_STAGING_DIR" 
"$ASAR_EXEC" extract app.asar app.asar.contents

echo "Creating stub native module..."
cat > app.asar.contents/node_modules/claude-native/index.js << EOF
// Stub implementation of claude-native using KeyboardKey enum values
const KeyboardKey = { Backspace: 43, Tab: 280, Enter: 261, Shift: 272, Control: 61, Alt: 40, CapsLock: 56, Escape: 85, Space: 276, PageUp: 251, PageDown: 250, End: 83, Home: 154, LeftArrow: 175, UpArrow: 282, RightArrow: 262, DownArrow: 81, Delete: 79, Meta: 187 };
Object.freeze(KeyboardKey);
module.exports = { getWindowsVersion: () => "10.0.0", setWindowEffect: () => {}, removeWindowEffect: () => {}, getIsMaximized: () => false, flashFrame: () => {}, clearFlashFrame: () => {}, showNotification: () => {}, setProgressBar: () => {}, clearProgressBar: () => {}, setOverlayIcon: () => {}, clearOverlayIcon: () => {}, KeyboardKey };
EOF

mkdir -p app.asar.contents/resources
mkdir -p app.asar.contents/resources/i18n
cp "$CLAUDE_EXTRACT_DIR/lib/net45/resources/Tray"* app.asar.contents/resources/
cp "$CLAUDE_EXTRACT_DIR/lib/net45/resources/"*-*.json app.asar.contents/resources/i18n/

echo "##############################################################"
echo "Removing "'!'" from 'if ("'!'"isWindows && isMainWindow) return null;'"
echo "detection flag to to enable title bar"

echo "Current working directory: '$PWD'"

SEARCH_BASE="app.asar.contents/.vite/renderer/main_window/assets"
TARGET_PATTERN="MainWindowPage-*.js"

echo "Searching for '$TARGET_PATTERN' within '$SEARCH_BASE'..."
# Find the target file recursively (ensure only one matches)
TARGET_FILES=$(find "$SEARCH_BASE" -type f -name "$TARGET_PATTERN")
# Count non-empty lines to get the number of files found
NUM_FILES=$(echo "$TARGET_FILES" | grep -c .)

if [ "$NUM_FILES" -eq 0 ]; then
  echo "Error: No file matching '$TARGET_PATTERN' found within '$SEARCH_BASE'." >&2
  exit 1
elif [ "$NUM_FILES" -gt 1 ]; then
  echo "Error: Expected exactly one file matching '$TARGET_PATTERN' within '$SEARCH_BASE', but found $NUM_FILES." >&2
  echo "Found files:" >&2
  echo "$TARGET_FILES" >&2
  exit 1
else
  # Exactly one file found
  TARGET_FILE="$TARGET_FILES" # Assign the found file path
  echo "Found target file: $TARGET_FILE"
  echo "Attempting to replace patterns like 'if(!VAR1 && VAR2)' with 'if(VAR1 && VAR2)' in $TARGET_FILE..."
  # Use character classes [a-zA-Z]+ to match minified variable names
  # Capture group 1: first variable name
  # Capture group 2: second variable name
  sed -i -E 's/if\(!([a-zA-Z]+)[[:space:]]*&&[[:space:]]*([a-zA-Z]+)\)/if(\1 \&\& \2)/g' "$TARGET_FILE"

  # Verification: Check if the original pattern structure still exists
  if ! grep -q -E 'if\(![a-zA-Z]+[[:space:]]*&&[[:space:]]*[a-zA-Z]+\)' "$TARGET_FILE"; then
    echo "Successfully replaced patterns like 'if(!VAR1 && VAR2)' with 'if(VAR1 && VAR2)' in $TARGET_FILE"
  else
    echo "Error: Failed to replace patterns like 'if(!VAR1 && VAR2)' in $TARGET_FILE. Check file contents." >&2
    exit 1
  fi
fi
echo "##############################################################"

"$ASAR_EXEC" pack app.asar.contents app.asar

mkdir -p "$APP_STAGING_DIR/app.asar.unpacked/node_modules/claude-native"
cat > "$APP_STAGING_DIR/app.asar.unpacked/node_modules/claude-native/index.js" << EOF
// Stub implementation of claude-native using KeyboardKey enum values
const KeyboardKey = { Backspace: 43, Tab: 280, Enter: 261, Shift: 272, Control: 61, Alt: 40, CapsLock: 56, Escape: 85, Space: 276, PageUp: 251, PageDown: 250, End: 83, Home: 154, LeftArrow: 175, UpArrow: 282, RightArrow: 262, DownArrow: 81, Delete: 79, Meta: 187 };
Object.freeze(KeyboardKey);
module.exports = { getWindowsVersion: () => "10.0.0", setWindowEffect: () => {}, removeWindowEffect: () => {}, getIsMaximized: () => false, flashFrame: () => {}, clearFlashFrame: () => {}, showNotification: () => {}, setProgressBar: () => {}, clearProgressBar: () => {}, setOverlayIcon: () => {}, clearOverlayIcon: () => {}, KeyboardKey };
EOF

echo "Copying chosen electron installation to staging area..."
mkdir -p "$APP_STAGING_DIR/node_modules/"
ELECTRON_DIR_NAME=$(basename "$CHOSEN_ELECTRON_MODULE_PATH")
echo "Copying from $CHOSEN_ELECTRON_MODULE_PATH to $APP_STAGING_DIR/node_modules/"
cp -a "$CHOSEN_ELECTRON_MODULE_PATH" "$APP_STAGING_DIR/node_modules/" 
STAGED_ELECTRON_BIN="$APP_STAGING_DIR/node_modules/$ELECTRON_DIR_NAME/dist/electron"
if [ -f "$STAGED_ELECTRON_BIN" ]; then
    echo "Setting executable permission on staged Electron binary: $STAGED_ELECTRON_BIN"
    chmod +x "$STAGED_ELECTRON_BIN"
else
    echo "Warning: Staged Electron binary not found at expected path: $STAGED_ELECTRON_BIN"
fi

# Ensure Electron locale files are available
# Check for standard npm structure first, then Nix structure
if [ -d "$CHOSEN_ELECTRON_MODULE_PATH/dist/resources" ]; then
    ELECTRON_RESOURCES_SRC="$CHOSEN_ELECTRON_MODULE_PATH/dist/resources"
elif [ -d "$CHOSEN_ELECTRON_MODULE_PATH/dist/libexec/electron/resources" ]; then
    # Nix electron-unwrapped structure
    ELECTRON_RESOURCES_SRC="$CHOSEN_ELECTRON_MODULE_PATH/dist/libexec/electron/resources"
else
    ELECTRON_RESOURCES_SRC=""
fi

ELECTRON_RESOURCES_DEST="$APP_STAGING_DIR/node_modules/$ELECTRON_DIR_NAME/dist/resources"
if [ -n "$ELECTRON_RESOURCES_SRC" ] && [ -d "$ELECTRON_RESOURCES_SRC" ]; then
    echo "Copying Electron locale resources..."
    mkdir -p "$ELECTRON_RESOURCES_DEST"
    cp -a "$ELECTRON_RESOURCES_SRC"/* "$ELECTRON_RESOURCES_DEST/"
    echo "✓ Electron locale resources copied"
else
    echo "⚠️  Warning: Electron resources directory not found"
    echo "   Tried: $CHOSEN_ELECTRON_MODULE_PATH/dist/resources"
    echo "   Tried: $CHOSEN_ELECTRON_MODULE_PATH/dist/libexec/electron/resources"
    # Create resources directory anyway for locale files
    mkdir -p "$ELECTRON_RESOURCES_DEST"
fi

# Copy Claude locale JSON files to Electron resources directory where they're expected
CLAUDE_LOCALE_SRC="$CLAUDE_EXTRACT_DIR/lib/net45/resources"
echo "Copying Claude locale JSON files to Electron resources directory..."
if [ -d "$CLAUDE_LOCALE_SRC" ]; then
    # Copy Claude's locale JSON files to the Electron resources directory
    cp "$CLAUDE_LOCALE_SRC/"*-*.json "$ELECTRON_RESOURCES_DEST/" 2>/dev/null || echo "⚠️  Warning: Failed to copy some locale files"
    echo "✓ Claude locale JSON files copied to Electron resources directory"
else
    echo "⚠️  Warning: Claude locale source directory not found at $CLAUDE_LOCALE_SRC"
fi

echo "✓ app.asar processed and staged in $APP_STAGING_DIR"

cd "$PROJECT_ROOT"

echo -e "\033[1;36m--- Call Packaging Script ---\033[0m"
FINAL_OUTPUT_PATH="" FINAL_DESKTOP_FILE_PATH="" 
if [ "$BUILD_FORMAT" = "deb" ]; then
    echo "📦 Calling Debian packaging script for $ARCHITECTURE..."
    chmod +x scripts/build-deb-package.sh
    if ! scripts/build-deb-package.sh \
        "$VERSION" "$ARCHITECTURE" "$WORK_DIR" "$APP_STAGING_DIR" \
        "$PACKAGE_NAME" "$MAINTAINER" "$DESCRIPTION"; then
        echo "❌ Debian packaging script failed."
        exit 1
    fi
    DEB_FILE=$(find "$WORK_DIR" -maxdepth 1 -name "${PACKAGE_NAME}_${VERSION}_${ARCHITECTURE}.deb" | head -n 1)
    echo "✓ Debian Build complete!"
    if [ -n "$DEB_FILE" ] && [ -f "$DEB_FILE" ]; then
        FINAL_OUTPUT_PATH="./$(basename "$DEB_FILE")" # Set final path using basename directly
        mv "$DEB_FILE" "$FINAL_OUTPUT_PATH"
        echo "Package created at: $FINAL_OUTPUT_PATH"
    else
        echo "Warning: Could not determine final .deb file path from $WORK_DIR for ${ARCHITECTURE}."
        FINAL_OUTPUT_PATH="Not Found"
    fi

elif [ "$BUILD_FORMAT" = "appimage" ]; then
    echo "📦 Calling AppImage packaging script for $ARCHITECTURE..."
    chmod +x scripts/build-appimage.sh
    if ! scripts/build-appimage.sh \
        "$VERSION" "$ARCHITECTURE" "$WORK_DIR" "$APP_STAGING_DIR" "$PACKAGE_NAME"; then
        echo "❌ AppImage packaging script failed."
        exit 1
    fi
    APPIMAGE_FILE=$(find "$WORK_DIR" -maxdepth 1 -name "${PACKAGE_NAME}-${VERSION}-${ARCHITECTURE}.AppImage" | head -n 1)
    echo "✓ AppImage Build complete!"
    if [ -n "$APPIMAGE_FILE" ] && [ -f "$APPIMAGE_FILE" ]; then
        FINAL_OUTPUT_PATH="./$(basename "$APPIMAGE_FILE")" 
        mv "$APPIMAGE_FILE" "$FINAL_OUTPUT_PATH"
        echo "Package created at: $FINAL_OUTPUT_PATH"

        echo -e "\033[1;36m--- Generate .desktop file for AppImage ---\033[0m"
        FINAL_DESKTOP_FILE_PATH="./${PACKAGE_NAME}-appimage.desktop"
        echo "📝 Generating .desktop file for AppImage at $FINAL_DESKTOP_FILE_PATH..."
        cat > "$FINAL_DESKTOP_FILE_PATH" << EOF
[Desktop Entry]
Name=Claude (AppImage)
Comment=Claude Desktop (AppImage Version $VERSION)
Exec=$(basename "$FINAL_OUTPUT_PATH") %u
Icon=claude-desktop
Type=Application
Terminal=false
Categories=Office;Utility;Network;
MimeType=x-scheme-handler/claude;
StartupWMClass=Claude
X-AppImage-Version=$VERSION
X-AppImage-Name=Claude Desktop (AppImage)
EOF
        echo "✓ .desktop file generated."

    else
        echo "Warning: Could not determine final .AppImage file path from $WORK_DIR for ${ARCHITECTURE}."
        FINAL_OUTPUT_PATH="Not Found"
    fi
fi


echo -e "\033[1;36m--- Cleanup ---\033[0m"
if [ "$PERFORM_CLEANUP" = true ]; then     echo "🧹 Cleaning up intermediate build files in $WORK_DIR..."
        if rm -rf "$WORK_DIR"; then
        echo "✓ Cleanup complete ($WORK_DIR removed)."
    else
        echo "⚠️ Cleanup command (rm -rf $WORK_DIR) failed."
    fi
else
    echo "Skipping cleanup of intermediate build files in $WORK_DIR."
fi


echo "✅ Build process finished."

echo -e "\n\033[1;34m====== Next Steps ======\033[0m"
if [ "$BUILD_FORMAT" = "deb" ]; then
    if [ "$FINAL_OUTPUT_PATH" != "Not Found" ] && [ -e "$FINAL_OUTPUT_PATH" ]; then
        echo -e "📦 To install the Debian package, run:"
        echo -e "   \033[1;32msudo apt install $FINAL_OUTPUT_PATH\033[0m"
        echo -e "   (or \`sudo dpkg -i $FINAL_OUTPUT_PATH\`)"
    else
        echo -e "⚠️ Debian package file not found. Cannot provide installation instructions."
    fi
elif [ "$BUILD_FORMAT" = "appimage" ]; then
    if [ "$FINAL_OUTPUT_PATH" != "Not Found" ] && [ -e "$FINAL_OUTPUT_PATH" ]; then
        echo -e "✅ AppImage created at: \033[1;36m$FINAL_OUTPUT_PATH\033[0m"
        echo -e "\n\033[1;33mIMPORTANT:\033[0m This AppImage requires \033[1;36mGear Lever\033[0m for proper desktop integration"
        echo -e "and to handle the \`claude://\` login process correctly."
        echo -e "\n🚀 To install Gear Lever:"
        echo -e "   1. Install via Flatpak:"
        echo -e "      \033[1;32mflatpak install flathub it.mijorus.gearlever\033[0m"
        echo -e "       - or visit: \033[1;34mhttps://flathub.org/apps/it.mijorus.gearlever\033[0m"
        echo -e "   2. Integrate your AppImage with just one click:"
        echo -e "      - Open Gear Lever"
        echo -e "      - Drag and drop \033[1;36m$FINAL_OUTPUT_PATH\033[0m into Gear Lever"
        echo -e "      - Click 'Integrate' to add it to your app menu"
        if [ "$GITHUB_ACTIONS" = "true" ]; then
            echo -e "\n   \033[1;32m✓\033[0m This AppImage includes embedded update information!"
            echo -e "   \033[1;32m✓\033[0m Gear Lever will automatically detect and handle updates from GitHub releases."
            echo -e "   \033[1;32m✓\033[0m No manual update URL configuration needed."
        else
            echo -e "\n   \033[1;33mℹ\033[0m This locally-built AppImage does not include update information."
            echo -e "   \033[1;33mℹ\033[0m You can manually configure updates in Gear Lever:"
            echo -e "   3. Configure manual updates (optional):"
            echo -e "      - In Gear Lever, select your integrated Claude Desktop"
            echo -e "      - Choose 'Github' as update source"
            echo -e "      - Use this update URL: \033[1;33mhttps://github.com/aaddrick/claude-desktop-debian/releases/download/*/claude-desktop-*-${ARCHITECTURE}.AppImage\033[0m"
            echo -e "   \033[1;34m→\033[0m For automatic updates, download release versions: https://github.com/aaddrick/claude-desktop-debian/releases"
        fi
    else
        echo -e "⚠️ AppImage file not found. Cannot provide usage instructions."
    fi
fi
echo -e "\033[1;34m======================\033[0m"

exit 0
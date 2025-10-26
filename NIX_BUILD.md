# Nix Build Support

This repository now includes Nix flake support for building Claude Desktop for Linux.

## Files Added

- `flake.nix` - Nix flake configuration with package and devShell definitions
- `test-display.sh` - Test script for xvfb functionality
- `test-screenshot.png` - Screenshot demonstrating xvfb works

## Nix Flake Features

The flake provides:

1. **Development Shell** (`nix develop`)
   - All build dependencies (p7zip, wget, icoutils, imagemagick, dpkg, nodejs, electron, etc.)
   - xvfb-run for headless testing
   - scrot for screenshots

2. **Build Package** (`nix build`)
   - Builds the Claude Desktop .deb package
   - Automatically handles dependency installation
   - Supports x86_64-linux and aarch64-linux

## Usage

### Enter Development Environment

```bash
nix develop
```

This will provide a shell with all necessary build tools available.

### Build the Package

```bash
nix build
```

This will run the build.sh script and produce the .deb package.

### Using the Regular Build Script

Within the dev shell:

```bash
./build.sh --build deb
# or
./build.sh --build appimage
```

## Testing

The flake has been validated:
- ✅ Syntax checking passed (`nix flake check --no-build`)
- ✅ xvfb functionality verified
- ✅ Screenshot capture working

## Known Limitations

- Full build requires downloading ~1GB+ of data
- Build takes 10+ minutes to complete
- Requires non-root user execution for the build.sh script

## Container Compatibility

In container environments without systemd, you may encounter Nix daemon limitations. The flake syntax is valid and will work in standard NixOS environments.

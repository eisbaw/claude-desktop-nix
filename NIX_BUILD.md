# Building Claude Desktop with Nix

This repository now includes a Nix flake for building Claude Desktop on NixOS and other Linux systems with Nix installed.

## Prerequisites

- Nix package manager with flakes enabled
- Internet connection to download the Claude Desktop installer

## Building

To build Claude Desktop using Nix:

```bash
# Build the package
nix build

# Run directly without installing
nix run

# Install to your profile
nix profile install
```

## Configuration

The flake supports both `x86_64-linux` and `aarch64-linux` architectures.

### First Build

On the first build attempt, you'll need to update the SHA256 hash for the downloaded installer:

1. Run `nix build` - it will fail with a hash mismatch error
2. Copy the "got:" hash from the error message
3. Update the `sha256` value in `flake.nix` for your architecture
4. Run `nix build` again

Example error:
```
hash mismatch in fixed-output derivation '/nix/store/...':
  specified: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
       got:    sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
```

Update the hash in flake.nix:
```nix
sha256 = "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=";
```

## NixOS Integration

### System-wide Installation

Add to your NixOS configuration:

```nix
{
  inputs.claude-desktop.url = "github:aaddrick/claude-desktop-debian";

  # In your configuration.nix:
  environment.systemPackages = [
    inputs.claude-desktop.packages.${system}.default
  ];
}
```

### Home Manager

Add to your home.nix:

```nix
{
  home.packages = [
    inputs.claude-desktop.packages.${pkgs.system}.default
  ];
}
```

## Running

After installation, you can run Claude Desktop:

```bash
claude-desktop
```

Or launch it from your application menu.

## Configuration Files

- Config: `~/.config/Claude/claude_desktop_config.json`
- Logs: `~/claude-desktop-launcher.log`

## Wayland Support

The launcher automatically detects Wayland and enables appropriate flags:
- Native Wayland backend via Ozone
- GlobalShortcuts Portal support
- IME support

## Troubleshooting

### Hash Mismatch
If you get a hash mismatch error, update the SHA256 hash as described above.

### Build Failures
Check that you have:
- Flakes enabled in your Nix configuration
- Internet access to download the installer
- Sufficient disk space

### Runtime Issues
Check the log file at `~/claude-desktop-launcher.log` for details.

## Comparison with build.sh

The Nix build provides several advantages over the traditional `build.sh`:

1. **Reproducibility**: Nix ensures the same inputs produce the same outputs
2. **No system pollution**: All dependencies are isolated in the Nix store
3. **Declarative**: The entire build process is defined in flake.nix
4. **Garbage collection**: Unused dependencies can be automatically cleaned up
5. **Rollbacks**: Easy to switch between versions

## Credits

Based on the original build scripts from this repository, which were inspired by:
- [k3d3's claude-desktop-linux-flake](https://github.com/k3d3/claude-desktop-linux-flake)
- [emsi's claude-desktop](https://github.com/emsi/claude-desktop)

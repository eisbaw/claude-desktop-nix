#!/bin/bash
# Run Claude Desktop in xvfb and take screenshot

# Start xvfb on display :99
Xvfb :99 -screen 0 1920x1080x24 &
XVFB_PID=$!

# Wait for X server to start
sleep 3

# Set DISPLAY
export DISPLAY=:99

# Run Claude Desktop in background
echo "Starting Claude Desktop..."
/usr/bin/claude-desktop &
CLAUDE_PID=$!

# Wait for Claude to initialize and render
echo "Waiting for Claude Desktop to start..."
sleep 15

# Take screenshot
echo "Taking screenshot..."
scrot /home/user/claude-desktop-nix/claude-desktop-screenshot.png

# Keep it running a bit longer to ensure screenshot captured properly
sleep 2

# Cleanup
echo "Cleaning up..."
kill $CLAUDE_PID 2>/dev/null || true
kill $XVFB_PID 2>/dev/null || true

echo "Screenshot saved to: /home/user/claude-desktop-nix/claude-desktop-screenshot.png"
ls -lh /home/user/claude-desktop-nix/claude-desktop-screenshot.png

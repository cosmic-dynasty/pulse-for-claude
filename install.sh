#!/bin/bash
# Pulse for Claude · one-line installer
# Usage: curl -fsSL https://raw.githubusercontent.com/cosmic-dynasty/pulse-for-claude/main/install.sh | bash
set -e

REPO="cosmic-dynasty/pulse-for-claude"
ZIP_URL="https://github.com/$REPO/releases/latest/download/Pulse-for-Claude.zip"
APP="/Applications/Pulse for Claude.app"

echo ""
echo "  Pulse for Claude · installer"
echo "  ----------------------------"

# 1. sanity checks
if [ "$(uname)" != "Darwin" ]; then
  echo "  This is a Mac app. Sorry!"; exit 1
fi
OSVER=$(sw_vers -productVersion | cut -d. -f1)
if [ "$OSVER" -lt 13 ]; then
  echo "  Needs macOS 13 or newer. You have $(sw_vers -productVersion)."; exit 1
fi
if [ ! -f "$HOME/.claude/.credentials.json" ] && ! security find-generic-password -s "Claude Code-credentials" -w > /dev/null 2>&1; then
  echo ""
  echo "  Heads up: no Claude Code login found on this Mac."
  echo "  Pulse reads the login you already have from Claude Code."
  echo "  Install Claude Code (or open the Claude desktop app's Code tab),"
  echo "  sign in once, then run this installer again. Installing anyway..."
  echo ""
fi

# 2. download
echo "  Downloading latest release..."
curl -fsSL -o /tmp/pulse-for-claude.zip "$ZIP_URL"

# 3. install
echo "  Installing to /Applications..."
osascript -e 'quit app "Pulse for Claude"' 2>/dev/null || true
sleep 1
rm -rf "$APP"
ditto -x -k /tmp/pulse-for-claude.zip /Applications/
rm /tmp/pulse-for-claude.zip

# 4. clear the download quarantine (free community app, not Apple-notarized;
#    the source is public at github.com/$REPO)
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

# 5. launch
echo "  Launching..."
open "$APP"

echo ""
echo "  Done! Look at the top-right of your screen, near the clock."
echo ""
echo "  A popup will ask to access 'Claude Code-credentials' in your"
echo "  keychain. That is Pulse reading your existing Claude login,"
echo "  which never leaves your Mac. Type your Mac password and click"
echo "  ALWAYS ALLOW. The ring goes live within a minute."
echo ""
echo "  Tip: click the ring, then turn on Launch at Login."
echo ""

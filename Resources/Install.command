#!/bin/bash
set -e

APP_NAME="PortForwarding.app"
SOURCE="$(dirname "$0")/$APP_NAME"
DEST="/Applications/$APP_NAME"

if [ ! -d "$SOURCE" ]; then
    echo "Error: $APP_NAME not found."
    exit 1
fi

if [ -d "$DEST" ]; then
    echo "Replacing existing installation..."
    rm -rf "$DEST"
fi

echo "Installing $APP_NAME to /Applications..."
cp -R "$SOURCE" "$DEST"
xattr -cr "$DEST"

echo "Launching $APP_NAME..."
open "$DEST"

echo "Done! You can close this window."

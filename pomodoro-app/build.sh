#!/bin/bash
# Build the native macOS Pomodoro menubar app from source (swiftc, no Xcode project).
#
# Usage:
#   ./build.sh                # build Pomodoro.app in this directory
#   ./build.sh --install      # also install to /Applications (replacing any existing copy)
#   ./build.sh --install --clear-notification-cache
#                             # additionally clear macOS's notification icon cache so
#                             # notification banners pick up the tomato icon immediately.
#                             # NOTE: this deletes the whole notification history.

set -euo pipefail
cd "$(dirname "$0")"

APP="Pomodoro"
BUNDLE_ID="com.local.pomodoro"

# 1. Compile the binary.
swiftc -O -parse-as-library Pomodoro.swift -o "$APP"

# 2. Assemble the .app bundle.
rm -rf "$APP.app"
mkdir -p "$APP.app/Contents/MacOS" "$APP.app/Contents/Resources"
cp "$APP" "$APP.app/Contents/MacOS/"
cp Info.plist "$APP.app/Contents/Info.plist"
cp AppIcon.icns "$APP.app/Contents/Resources/"
cp NotificationIcon.png "$APP.app/Contents/Resources/"

# 3. Ad-hoc sign (required for UNUserNotificationCenter).
codesign --force --deep --sign - "$APP.app"

echo "Built $PWD/$APP.app"

# 4. Optional install.
if [[ "${1:-}" == "--install" ]]; then
    # Quit the running instance so the bundle can be replaced.
    pkill -x "$APP" 2>/dev/null || true
    sleep 1
    rm -rf "/Applications/$APP.app"
    cp -R "$APP.app" /Applications/
    codesign --force --deep --sign - "/Applications/$APP.app"
    echo "Installed to /Applications/$APP.app"

    if [[ "${2:-}" == "--clear-notification-cache" ]]; then
        echo "Clearing Notification Center icon cache..."
        pkill -x usernoted 2>/dev/null || true
        sleep 1
        rm -rf /private/var/folders/*/*/0/com.apple.notificationcenter/db2
        echo "Cache cleared. Launch the app to re-register with macOS."
    fi
fi

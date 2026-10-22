#!/bin/bash
set -euo pipefail
APP=$1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
# Sign nested executables first. Restricted keychain entitlements are neither
# needed nor claimed by the login-keychain compatibility profile.
for COMPONENT in XPCServices/Downloader.xpc XPCServices/Installer.xpc Autoupdate Updater.app; do
  if [[ -e "$FRAMEWORK/Versions/Current/$COMPONENT" ]]; then
    codesign --force --sign - "$FRAMEWORK/Versions/Current/$COMPONENT"
  fi
done
codesign --force --sign - "$FRAMEWORK"
codesign --force --sign - --entitlements "$ROOT/glance/glance.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

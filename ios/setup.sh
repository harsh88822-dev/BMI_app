#!/usr/bin/env bash
# Regenerate iOS pods the same way on every Mac. Run from repo root.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> flutter pub get"
flutter pub get

if [[ ! -f ios/Flutter/Team.xcconfig ]]; then
  echo ""
  echo "WARNING: ios/Flutter/Team.xcconfig missing."
  echo "  cp ios/Flutter/Team.xcconfig.example ios/Flutter/Team.xcconfig"
  echo "  Then set DEVELOPMENT_TEAM to your Apple Team ID."
  echo ""
fi

echo "==> pod install"
cd ios
pod install --repo-update
cd ..

echo ""
echo "Done. Open: ios/Runner.xcworkspace (not .xcodeproj)"

# iOS developer setup — Clockwork BMI

Use this after every `git pull`. Your developer’s working config (ARCore 1.51, CocoaPods, Swift PM off) is in the repo; follow these steps so **every Mac** builds the same way.

**Always open `Runner.xcworkspace`** — never `Runner.xcodeproj`.

## Requirements (same on every Mac)

| Tool | Version |
|------|---------|
| macOS | Sonoma 14.5+ |
| **Xcode** | **26+** |
| Flutter | 3.38.x stable (`flutter --version`) |
| CocoaPods | 1.16+ (`pod --version`) |

Install CocoaPods if missing:

```bash
brew install cocoapods
# or: sudo gem install cocoapods
```

## One-time setup (after git clone / pull)

```bash
cd /path/to/Clockwork_BMI
flutter pub get

# Each developer uses their own Apple Team ID (not committed to git).
cp ios/Flutter/Team.xcconfig.example ios/Flutter/Team.xcconfig
# Edit Team.xcconfig → DEVELOPMENT_TEAM = <your 10-char Team ID>

./ios/setup.sh
open ios/Runner.xcworkspace
```

In Xcode: **Runner** → **Signing & Capabilities** → pick your **Team** (must match `Team.xcconfig`).

## Run on device

```bash
flutter run -d <iphone-device-id>
```

## Common errors

### “Podfile.lock out of sync” / CocoaPods mismatch

```bash
cd ios && pod install && cd ..
```

**`Podfile.lock` is committed** — run `pod install` after pull; do not delete the lock file unless instructed.

### `Generated.xcconfig` missing

```bash
flutter pub get
cd ios && pod install && cd ..
```

### Swift / module / “Could not build module”

```bash
cd ios
rm -rf Pods
pod install --repo-update
cd ..
flutter clean && flutter pub get
```

### Signing / provisioning

- Use **Automatic** signing in Xcode.
- Bundle ID: `com.clockworkbmi`
- Do **not** commit `ios/Flutter/Team.xcconfig`.

### Works on one Mac, fails on another

Usually:

1. Skipped `flutter pub get` before `pod install`
2. Opened `.xcodeproj` instead of `.xcworkspace`
3. Missing `Team.xcconfig` / wrong Team ID
4. Old `Pods/` folder — delete `ios/Pods` and re-run `./ios/setup.sh`

## TestFlight export

```bash
cp ios/ExportOptions.plist.example ios/ExportOptions.plist
# Set teamID in ExportOptions.plist

flutter build ipa --release --export-options-plist=ios/ExportOptions.plist
```

See also: [TESTFLIGHT.md](TESTFLIGHT.md)

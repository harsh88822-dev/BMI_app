# iOS / TestFlight — Clockwork BMI

Bundle ID: `com.clockworkbmi`  
Version: `1.0.1` (build `2`) — from `pubspec.yaml`  
Team: `5TD7B79GK6` (same as AR plugin example; change in Xcode if your Apple team differs)

## Prerequisites
1. Mac with **Xcode 26+** (App Store requires iOS 26 SDK since Apr 28, 2026)
2. Apple Developer account that owns `com.clockworkbmi`
3. Sign in to Xcode → Settings → Accounts
4. Confirm Team ID matches `DEVELOPMENT_TEAM` in `ios/Runner.xcodeproj`
5. Physical iPhone with ARKit (A12+). Simulator cannot run AR height
6. Deployment target: **iOS 15.5+** (runs on iOS 15.5 through latest iOS)

## Build & upload (recommended)

```bash
cd /Users/harshshah/Downloads/Clockwork_BMI
flutter clean
flutter pub get
cd ios && pod install && cd ..
flutter build ipa --release --export-options-plist=ios/ExportOptions.plist
```

IPA path: `build/ios/ipa/*.ipa`

Then:
- open [App Store Connect](https://appstoreconnect.apple.com) → TestFlight
- or drag the archive from Xcode Organizer after `open build/ios/archive/*.xcarchive`

### Alternate (Xcode UI)
```bash
open ios/Runner.xcworkspace
```
Product → Archive → Distribute App → App Store Connect → Upload

## TestFlight checklist
- [ ] App record exists for `com.clockworkbmi` in App Store Connect
- [ ] Push capability matches Firebase `GoogleService-Info.plist` (BUNDLE_ID)
- [ ] Export compliance: `ITSAppUsesNonExemptEncryption=false` already set
- [ ] Privacy Nutrition Labels / support URLs from `app_store_docs/`
- [ ] Internal testers invited; external needs Beta App Review

## Device test flow (same as Android)
1. Login → Start BMI → AR height → Confirm
2. Fit guide → Hold still → Record full circle (~12s bar)
3. Results show immediately; face verify uploads in background
4. Height/weight use the same calibrated constants as Android

## Notes
- Push entitlement uses `production` for TestFlight/App Store
- If archive signing fails, open the workspace, select Runner → Signing & Capabilities → pick your team
- If Team ID is wrong, replace `5TD7B79GK6` in `project.pbxproj` and `ExportOptions.plist`

# Platform / API support — Clockwork BMI

## Safe for the working app

These settings are **store/build metadata**. They do **not** change BMI math,
scan timing, camera pipeline, or AR height logic.

| Change | Runtime impact |
|--------|----------------|
| `targetSdk = 36` | Same as Flutter 3.38 default — Play compliance only |
| `compileSdk = 36` | Already in use before this update |
| `minSdk` | Still Flutter default (**24**) — same devices as before |
| iOS deployment **15.5** | Already set in Podfile/Xcode — AppFrameworkInfo aligned only |
| AR plugin `compileSdk 36` | Build fix for AGP 8; same ARCore 1.41 deps |

## Android (Google Play)

| Setting | Value |
|---------|-------|
| `compileSdk` | **36** |
| `targetSdk` | **36** (required for new apps/updates from 31 Aug 2026) |
| `minSdk` | **24** (unchanged) |

## iOS (App Store / TestFlight)

| Setting | Value |
|---------|-------|
| **Build SDK** | **iOS 26 SDK (Xcode 26+)** for uploads |
| **Deployment target** | **iOS 15.5** (unchanged; runs through latest iOS) |

App version: **1.0.2+3**

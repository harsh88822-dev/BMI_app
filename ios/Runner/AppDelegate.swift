import AVFoundation
import CoreMedia
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Register plugins / create the Flutter view first, then attach channels.
    let launched = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    registerCameraFovChannel()

    // Required for Firebase Cloud Messaging on iOS.
    application.registerForRemoteNotifications()

    return launched
  }

  private func registerCameraFovChannel() {
    guard
      let controller = window?.rootViewController as? FlutterViewController
        ?? (UIApplication.shared.connectedScenes
          .compactMap { $0 as? UIWindowScene }
          .flatMap { $0.windows }
          .first { $0.isKeyWindow }?
          .rootViewController as? FlutterViewController)
    else {
      // Retry once on next run-loop tick if the Flutter VC is not ready yet.
      DispatchQueue.main.async { [weak self] in
        self?.registerCameraFovChannel()
      }
      return
    }

    let channel = FlutterMethodChannel(
      name: "com.clockworkbmi.app/camera_fov",
      binaryMessenger: controller.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "getBackCameraVerticalFovDegrees":
        result(self?.readBackCameraVerticalFovDegrees() ?? 62.0)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Returns **vertical** FOV in degrees (matches Android Camera2 path).
  /// `AVCaptureDeviceFormat.videoFieldOfView` is horizontal — convert using
  /// the active format's dimensions.
  private func readBackCameraVerticalFovDegrees() -> Double {
    guard
      let device = AVCaptureDevice.default(
        .builtInWideAngleCamera,
        for: .video,
        position: .back
      )
    else {
      return 62.0
    }

    let format = device.activeFormat
    let horizontalFov = Double(format.videoFieldOfView)
    guard horizontalFov.isFinite, horizontalFov > 0 else {
      return 62.0
    }

    let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
    let width = Double(dims.width)
    let height = Double(dims.height)
    guard width > 0, height > 0 else {
      return horizontalFov
    }

    // Match Android Camera2: vertical FOV from the shorter sensor axis.
    let hFovRad = horizontalFov * .pi / 180.0
    let vFovRad = 2.0 * atan(tan(hFovRad / 2.0) * (height / width))
    let verticalFov = vFovRad * 180.0 / .pi

    if verticalFov.isFinite, verticalFov > 0 {
      return verticalFov
    }
    return horizontalFov
  }
}

/// Live face-verification status for ResultScreen (BMI can show first).
enum FaceVerificationPhase {
  /// Not started / not applicable.
  idle,

  /// Clip+upload running after BMI is already shown.
  pending,

  /// Server matched scan video to profile (ID) photo.
  verified,

  /// Server rejected face match.
  mismatch,

  /// Clip or upload failed — BMI remains a local estimate.
  unavailable,
}

class FaceVerificationState {
  const FaceVerificationState({
    required this.phase,
    this.message,
    this.serverMeasurement,
    this.videoPath,
  });

  final FaceVerificationPhase phase;
  final String? message;
  final Map<String, dynamic>? serverMeasurement;
  final String? videoPath;

  static const idle = FaceVerificationState(phase: FaceVerificationPhase.idle);

  static const pending = FaceVerificationState(
    phase: FaceVerificationPhase.pending,
    message: 'Verifying face against your ID profile photo…',
  );

  factory FaceVerificationState.verified({
    Map<String, dynamic>? serverMeasurement,
    String? videoPath,
  }) {
    return FaceVerificationState(
      phase: FaceVerificationPhase.verified,
      message: 'Face verified against your profile photo.',
      serverMeasurement: serverMeasurement,
      videoPath: videoPath,
    );
  }

  factory FaceVerificationState.mismatch(
    String message, {
    Map<String, dynamic>? serverMeasurement,
    String? videoPath,
  }) {
    return FaceVerificationState(
      phase: FaceVerificationPhase.mismatch,
      message: message,
      serverMeasurement: serverMeasurement,
      videoPath: videoPath,
    );
  }

  factory FaceVerificationState.unavailable(String message) {
    return FaceVerificationState(
      phase: FaceVerificationPhase.unavailable,
      message: message,
    );
  }
}

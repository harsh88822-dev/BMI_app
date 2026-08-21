import 'package:flutter/material.dart';

class CaptureControls extends StatelessWidget {
  final VoidCallback onRecordVideo;
  final bool isRecording;
  final bool isStarting;
  final bool isEnabled;

  const CaptureControls({
    Key? key,
    required this.onRecordVideo,
    required this.isRecording,
    this.isStarting = false,
    this.isEnabled = true,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FloatingActionButton(
          heroTag: "videoBtn",
          onPressed: isRecording
              ? onRecordVideo
              : (isEnabled && !isStarting ? onRecordVideo : null),
          backgroundColor: (isEnabled || isRecording)
              ? (isRecording ? Colors.cyan : Colors.white)
              : Colors.grey,
          child: isStarting
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.cyan,
                  ),
                )
              : Icon(
                  isRecording ? Icons.stop : Icons.videocam,
                  color: (isEnabled || isRecording)
                      ? (isRecording ? Colors.white : Colors.cyan)
                      : Colors.white24,
                ),
        ),
      ],
    );
  }
}

import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

/// Minimal owned copy of a [CameraImage] suitable for [compute] isolates.
class CameraFrameSnapshot {
  final int width;
  final int height;
  final bool singlePlane;
  final Uint8List yBytes;
  final int yRowStride;
  final Uint8List? uBytes;
  final Uint8List? vBytes;
  final int uvRowStride;
  final int uvPixelStride;

  const CameraFrameSnapshot({
    required this.width,
    required this.height,
    required this.singlePlane,
    required this.yBytes,
    required this.yRowStride,
    this.uBytes,
    this.vBytes,
    this.uvRowStride = 0,
    this.uvPixelStride = 1,
  });

  /// Fast synchronous grab before CameraX recycles buffers.
  static CameraFrameSnapshot? capture(CameraImage image) {
    if (image.planes.isEmpty || image.width <= 0 || image.height <= 0) {
      return null;
    }

    if (image.planes.length == 1) {
      final plane = image.planes.first;
      return CameraFrameSnapshot(
        width: image.width,
        height: image.height,
        singlePlane: true,
        yBytes: Uint8List.fromList(plane.bytes),
        yRowStride: plane.bytesPerRow,
      );
    }

    if (image.planes.length < 3) return null;
    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];
    return CameraFrameSnapshot(
      width: image.width,
      height: image.height,
      singlePlane: false,
      yBytes: Uint8List.fromList(yPlane.bytes),
      yRowStride: yPlane.bytesPerRow,
      uBytes: Uint8List.fromList(uPlane.bytes),
      vBytes: Uint8List.fromList(vPlane.bytes),
      uvRowStride: uPlane.bytesPerRow,
      uvPixelStride: uPlane.bytesPerPixel ?? 1,
    );
  }

  Uint8List? packNv21() {
    if (singlePlane) return yBytes;
    final u = uBytes;
    final v = vBytes;
    if (u == null || v == null) return null;

    final out = Uint8List(width * height + (width * height ~/ 2));
    var outIndex = 0;

    for (var y = 0; y < height; y++) {
      final yRow = y * yRowStride;
      for (var x = 0; x < width; x++) {
        out[outIndex++] = yBytes[yRow + x];
      }
    }

    for (var y = 0; y < height; y += 2) {
      final uvRow = (y ~/ 2) * uvRowStride;
      for (var x = 0; x < width; x += 2) {
        final uvIndex = uvRow + (x ~/ 2) * uvPixelStride;
        if (uvIndex >= v.length || uvIndex >= u.length) continue;
        out[outIndex++] = v[uvIndex];
        out[outIndex++] = u[uvIndex];
      }
    }
    return out;
  }
}

Uint8List? _packNv21OnIsolate(CameraFrameSnapshot snapshot) =>
    snapshot.packNv21();

Future<Uint8List?> packNv21Async(CameraFrameSnapshot snapshot) {
  return compute(_packNv21OnIsolate, snapshot);
}

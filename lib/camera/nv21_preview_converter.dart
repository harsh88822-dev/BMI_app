import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

/// Converts camera frames to [ui.Image] for live preview while recording.
abstract final class Nv21PreviewConverter {
  /// Snapshot plane bytes immediately — CameraImage buffers are recycled.
  static Uint8List? copyFrameBytes(CameraImage image) {
    if (image.planes.isEmpty) return null;
    if (image.planes.length == 1) {
      return Uint8List.fromList(image.planes.first.bytes);
    }
    // YUV_420_888 (3 planes) → pack to NV21 for conversion.
    return _yuv420ToNv21(image);
  }

  static Future<ui.Image?> fromCopiedNv21({
    required Uint8List nv21,
    required int width,
    required int height,
  }) async {
    if (width <= 0 || height <= 0) return null;
    final rgba = _nv21ToRgba(nv21, width, height);
    if (rgba == null) return null;

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.rgba8888,
      completer.complete,
      rowBytes: width * 4,
    );
    return completer.future;
  }

  static Future<ui.Image?> fromCameraImage(CameraImage image) async {
    final bytes = copyFrameBytes(image);
    if (bytes == null) return null;
    return fromCopiedNv21(
      nv21: bytes,
      width: image.width,
      height: image.height,
    );
  }

  static Uint8List? _yuv420ToNv21(CameraImage image) {
    final width = image.width;
    final height = image.height;
    if (image.planes.length < 3 || width <= 0 || height <= 0) return null;

    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];
    final yRowStride = yPlane.bytesPerRow;
    final uvRowStride = uPlane.bytesPerRow;
    final uvPixelStride = uPlane.bytesPerPixel ?? 1;

    final out = Uint8List(width * height + (width * height ~/ 2));
    var outIndex = 0;

    for (var y = 0; y < height; y++) {
      final yRow = y * yRowStride;
      for (var x = 0; x < width; x++) {
        out[outIndex++] = yPlane.bytes[yRow + x];
      }
    }

    // NV21 = YYYY… + interleaved V/U
    for (var y = 0; y < height; y += 2) {
      final uvRow = (y ~/ 2) * uvRowStride;
      for (var x = 0; x < width; x += 2) {
        final uvIndex = uvRow + (x ~/ 2) * uvPixelStride;
        if (uvIndex >= vPlane.bytes.length || uvIndex >= uPlane.bytes.length) {
          continue;
        }
        out[outIndex++] = vPlane.bytes[uvIndex];
        out[outIndex++] = uPlane.bytes[uvIndex];
      }
    }
    return out;
  }

  static Uint8List? _nv21ToRgba(Uint8List nv21, int width, int height) {
    final frameSize = width * height;
    if (nv21.length < frameSize + (frameSize >> 1)) return null;

    final rgba = Uint8List(frameSize * 4);
    for (var y = 0; y < height; y++) {
      final yRow = y * width;
      final uvRow = frameSize + (y >> 1) * width;
      for (var x = 0; x < width; x++) {
        final yIndex = yRow + x;
        final uvIndex = uvRow + (x & ~1);
        final yValue = nv21[yIndex] & 0xFF;
        final v = (nv21[uvIndex] & 0xFF) - 128;
        final u = (nv21[uvIndex + 1] & 0xFF) - 128;

        final r = (yValue + 1.402 * v).round().clamp(0, 255);
        final g = (yValue - 0.344136 * u - 0.714136 * v).round().clamp(0, 255);
        final b = (yValue + 1.772 * u).round().clamp(0, 255);

        final rgbaIndex = yIndex * 4;
        rgba[rgbaIndex] = r;
        rgba[rgbaIndex + 1] = g;
        rgba[rgbaIndex + 2] = b;
        rgba[rgbaIndex + 3] = 255;
      }
    }
    return rgba;
  }

  /// Match [CameraPreview] layout. ImageAnalysis is usually a landscape
  /// buffer that needs +90°. VideoCapture onAvailable is often already
  /// portrait — rotating again laid the person on their side.
  static Widget buildPreview({
    required ui.Image image,
    required CameraController controller,
  }) {
    final isLandscapeBuffer = image.width > image.height;
    final displayW =
        (isLandscapeBuffer ? image.height : image.width).toDouble();
    final displayH =
        (isLandscapeBuffer ? image.width : image.height).toDouble();
    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: displayW,
          height: displayH,
          child: RotatedBox(
            quarterTurns: isLandscapeBuffer ? 1 : 0,
            child: RawImage(image: image, fit: BoxFit.fill),
          ),
        ),
      ),
    );
  }
}

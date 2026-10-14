import 'dart:math' as math;
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;

const busDoorModelHash =
    '7178a76b3abaa83bfac0ad9c5b1ea40627560d6aa0e05587b335950a1bffaa85';
void verifyModel(Uint8List bytes) {
  if (bytes.isEmpty ||
      bytes.length > 16 * 1024 * 1024 ||
      sha256.convert(bytes).toString() != busDoorModelHash) {
    throw const FormatException('버스·문 모델 SHA256이 일치하지 않습니다.');
  }
}

class FramePlane {
  FramePlane(this.bytes, this.rowStride, this.pixelStride);
  final Uint8List bytes;
  final int rowStride, pixelStride;
  int at(int x, int y) {
    final i = y * rowStride + x * pixelStride;
    if (i < 0 || i >= bytes.length) {
      throw const FormatException('프레임 plane/stride 범위 오류');
    }
    return bytes[i];
  }
}

class VisionFrame {
  VisionFrame(
      {required this.width,
      required this.height,
      required this.format,
      required this.planes,
      required this.rotation,
      required this.mirror,
      required this.receivedAt,
      required this.receivedMicros});
  final int width, height, rotation, receivedMicros;
  final String format;
  final List<FramePlane> planes;
  final bool mirror;
  final DateTime receivedAt; // Host callback time, NOT sensor exposure time.
  VisionFrame metadata() => VisionFrame(
      width: width,
      height: height,
      format: format,
      planes: const [],
      rotation: rotation,
      mirror: mirror,
      receivedAt: receivedAt,
      receivedMicros: receivedMicros);
}

class LocalBox {
  const LocalBox(this.classId, this.confidence, this.x, this.y, this.w, this.h);
  final String classId;
  final double confidence, x, y, w, h;
}

class PreparedFrame {
  PreparedFrame(
      this.image, this.tensor, this.scaleX, this.scaleY, this.padX, this.padY);
  final img.Image image;
  final Float32List tensor;
  final double scaleX, scaleY;
  final int padX, padY;
}

int frameRotation(int sensor, int deviceDegrees, bool front) =>
    (sensor + (front ? deviceDegrees : -deviceDegrees) + 360) % 360;

// Match the verified Python decoder's integer placement (ties to even).
int roundModelPixel(double value) {
  final lower = value.floor(), fraction = value - value.floor();
  if (fraction == .5) return lower.isEven ? lower : lower + 1;
  return value.round();
}

PreparedFrame prepareFrame(VisionFrame frame) {
  if (frame.width <= 0 ||
      frame.height <= 0 ||
      frame.width * frame.height > 4096 * 4096 ||
      ![0, 90, 180, 270].contains(frame.rotation)) {
    throw const FormatException('지원하지 않는 프레임 해상도/회전');
  }
  void layout(FramePlane p, int columns, int rows, int channels) {
    if (p.pixelStride < 1 ||
        p.rowStride < (columns - 1) * p.pixelStride + channels ||
        p.bytes.length <
            (rows - 1) * p.rowStride +
                (columns - 1) * p.pixelStride +
                channels) {
      throw const FormatException('잘못된 plane 길이 또는 row/pixel stride');
    }
  }

  if (frame.format == 'yuv420' && frame.planes.length == 3) {
    layout(frame.planes[0], frame.width, frame.height, 1);
    layout(frame.planes[1], (frame.width + 1) ~/ 2, (frame.height + 1) ~/ 2, 1);
    layout(frame.planes[2], (frame.width + 1) ~/ 2, (frame.height + 1) ~/ 2, 1);
  } else if (frame.format == 'nv21' && frame.planes.length == 1) {
    final p = frame.planes[0];
    if (frame.width.isOdd ||
        frame.height.isOdd ||
        p.pixelStride != 1 ||
        p.rowStride < frame.width ||
        p.bytes.length <
            p.rowStride * frame.height +
                (frame.height ~/ 2 - 1) * p.rowStride +
                frame.width) {
      throw const FormatException('지원하지 않는 NV21 배치');
    }
  } else if (frame.format == 'bgra8888' && frame.planes.length == 1) {
    if (frame.planes[0].pixelStride != 4) {
      throw const FormatException('잘못된 BGRA pixel stride');
    }
    layout(frame.planes[0], frame.width, frame.height, 4);
  } else {
    throw const FormatException('지원하지 않는 이미지 plane 형식');
  }
  final image = img.Image(width: frame.width, height: frame.height);
  int byte(num v) => v.round().clamp(0, 255);
  for (var y = 0; y < frame.height; y++) {
    for (var x = 0; x < frame.width; x++) {
      int r, g, b;
      if (frame.format == 'yuv420' && frame.planes.length == 3) {
        final yy = frame.planes[0].at(x, y) - 16;
        final u = frame.planes[1].at(x ~/ 2, y ~/ 2) - 128;
        final v = frame.planes[2].at(x ~/ 2, y ~/ 2) - 128;
        r = byte((298 * yy + 409 * v) / 256);
        g = byte((298 * yy - 100 * u - 208 * v) / 256);
        b = byte((298 * yy + 516 * u) / 256);
      } else if (frame.format == 'nv21' && frame.planes.length == 1) {
        final p = frame.planes[0], yy = p.at(x, y) - 16;
        final i =
            p.rowStride * frame.height + (y ~/ 2) * p.rowStride + (x ~/ 2) * 2;
        if (i + 1 >= p.bytes.length) {
          throw const FormatException('잘못된 NV21 plane');
        }
        final v = p.bytes[i] - 128, u = p.bytes[i + 1] - 128;
        r = byte((298 * yy + 409 * v) / 256);
        g = byte((298 * yy - 100 * u - 208 * v) / 256);
        b = byte((298 * yy + 516 * u) / 256);
      } else if (frame.format == 'bgra8888' && frame.planes.length == 1) {
        final p = frame.planes[0], i = y * p.rowStride + x * 4;
        if (i + 3 >= p.bytes.length) {
          throw const FormatException('잘못된 BGRA plane');
        }
        b = p.bytes[i];
        g = p.bytes[i + 1];
        r = p.bytes[i + 2];
      } else {
        throw const FormatException('지원하지 않는 카메라 이미지 형식');
      }
      image.setPixelRgb(x, y, r, g, b);
    }
  }
  var upright = frame.rotation == 0
      ? image
      : img.copyRotate(image, angle: frame.rotation);
  if (frame.mirror) upright = img.flipHorizontal(upright);
  final scale = math.min(640 / upright.width, 640 / upright.height);
  final rw = roundModelPixel(upright.width * scale),
      rh = roundModelPixel(upright.height * scale);
  final px = roundModelPixel((640 - rw) / 2),
      py = roundModelPixel((640 - rh) / 2);
  final resized = img.copyResize(upright,
      width: rw, height: rh, interpolation: img.Interpolation.linear);
  final input = Float32List(640 * 640 * 3)
    ..fillRange(0, 640 * 640 * 3, 114 / 255);
  for (var y = 0; y < rh; y++) {
    for (var x = 0; x < rw; x++) {
      final p = resized.getPixel(x, y), i = ((y + py) * 640 + x + px) * 3;
      input[i] = p.r / 255;
      input[i + 1] = p.g / 255;
      input[i + 2] = p.b / 255;
    }
  }
  return PreparedFrame(
      upright, input, rw / upright.width, rh / upright.height, px, py);
}

List<LocalBox> decodeBoxes(Float32List output, PreparedFrame frame,
    {int candidates = 8400}) {
  if (output.length != 6 * candidates) {
    throw const FormatException('출력 tensor 크기 오류');
  }
  final boxes = <LocalBox>[];
  double bounded(double v, int size) => v.clamp(0, size.toDouble());
  for (var c = 0; c < 2; c++) {
    final raw = <LocalBox>[];
    for (var i = 0; i < candidates; i++) {
      final score = output[(4 + c) * candidates + i];
      if (!score.isFinite || score < 0 || score > 1) {
        throw const FormatException('잘못된 confidence');
      }
      if (score < .5) continue;
      final cx = output[i],
          cy = output[candidates + i],
          w = output[2 * candidates + i],
          h = output[3 * candidates + i];
      if (![cx, cy, w, h].every((v) => v.isFinite) || w <= 0 || h <= 0) {
        throw const FormatException('잘못된 bbox');
      }
      final iw = frame.image.width, ih = frame.image.height;
      final x1 = bounded(((cx - w / 2) * 640 - frame.padX) / frame.scaleX, iw);
      final y1 = bounded(((cy - h / 2) * 640 - frame.padY) / frame.scaleY, ih);
      final x2 = bounded(((cx + w / 2) * 640 - frame.padX) / frame.scaleX, iw);
      final y2 = bounded(((cy + h / 2) * 640 - frame.padY) / frame.scaleY, ih);
      if (x2 > x1 && y2 > y1) {
        raw.add(LocalBox(c == 0 ? 'bus' : 'bus_door', score, x1 / iw, y1 / ih,
            (x2 - x1) / iw, (y2 - y1) / ih));
      }
    }
    raw.sort((a, b) => b.confidence.compareTo(a.confidence));
    final kept = <LocalBox>[];
    for (final box in raw) {
      if (kept.every((other) => _iou(box, other) < .45)) kept.add(box);
    }
    boxes.addAll(kept);
  }
  return boxes;
}

double _iou(LocalBox a, LocalBox b) {
  final overlap =
      math.max(0.0, math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x)) *
          math.max(0.0, math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y));
  return overlap / (a.w * a.h + b.w * b.h - overlap);
}

class LocalObservation {
  LocalObservation(this.frame, this.jpeg, this.boxes, this.width, this.height,
      this.inferenceMs, this.processingMs);
  final VisionFrame frame;
  final Uint8List jpeg;
  final List<LocalBox> boxes;
  final int width, height;
  final double inferenceMs, processingMs;
}

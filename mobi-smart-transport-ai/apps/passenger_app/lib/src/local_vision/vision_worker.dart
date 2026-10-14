import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';
import 'vision_codec.dart';

/// Entire preprocessing/inference/postprocessing pipeline owns one native
/// interpreter in a worker isolate. No network or authentication dependency.
class VisionWorker {
  final ReceivePort _responses = ReceivePort();
  final ReceivePort _errors = ReceivePort();
  final ReceivePort _exits = ReceivePort();
  final Completer<void> _ready = Completer<void>();
  Completer<LocalObservation>? _pending;
  final Completer<void> _closed = Completer<void>();
  SendPort? _commands;
  bool _closing = false;
  double loadMs = 0, warmUpMs = 0;

  static Future<VisionWorker> open(Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > 16 * 1024 * 1024) {
      throw const FormatException('모델 파일 크기 오류');
    }
    final worker = VisionWorker();
    worker._responses.listen((message) {
      if (message is SendPort) {
        worker._commands = message;
      } else if (message is Map && message['ready'] == true) {
        worker.loadMs = message['load'] as double;
        worker.warmUpMs = message['warm'] as double;
        worker._ready.complete();
      } else if (message is LocalObservation) {
        worker._pending?.complete(message);
        worker._pending = null;
      } else if (message == 'closed') {
        if (!worker._closed.isCompleted) worker._closed.complete();
      } else if (message is String) {
        final e = StateError(message);
        if (!worker._ready.isCompleted) worker._ready.completeError(e);
        worker._pending?.completeError(e);
        worker._pending = null;
      }
    });
    void failed() {
      const text = 'TFLite 작업 프로세스가 종료되었습니다.';
      if (!worker._ready.isCompleted) {
        worker._ready.completeError(StateError(text));
      }
      worker._pending?.completeError(StateError(text));
      worker._pending = null;
      if (!worker._closed.isCompleted) worker._closed.complete();
    }

    worker._errors.listen((_) => failed());
    worker._exits.listen((_) => failed());
    try {
      await Isolate.spawn(_runWorker, (worker._responses.sendPort, bytes),
          onError: worker._errors.sendPort, onExit: worker._exits.sendPort);
      await worker._ready.future;
      return worker;
    } catch (_) {
      await worker.close();
      rethrow;
    }
  }

  Future<LocalObservation> infer(VisionFrame frame) {
    if (_closing || _pending != null) throw StateError('추론 중복/종료 후 호출');
    final pending = _pending = Completer<LocalObservation>();
    _commands!.send(frame);
    return pending.future;
  }

  Future<void> close() async {
    if (_closing) return _closed.future;
    _closing = true;
    // Native invoke is not force-killed; release it after the in-flight work.
    try {
      await _pending?.future;
    } catch (_) {/* already reported */}
    _commands?.send('close');
    if (_commands == null && !_closed.isCompleted) _closed.complete();
    await _closed.future;
    _responses.close();
    _errors.close();
    _exits.close();
  }
}

Future<void> _runWorker((SendPort, Uint8List) args) async {
  Interpreter? interpreter;
  final port = ReceivePort();
  args.$1.send(port.sendPort);
  try {
    verifyModel(args.$2);
    final watch = Stopwatch()..start();
    final options = InterpreterOptions()..threads = 2;
    try {
      interpreter = Interpreter.fromBuffer(args.$2, options: options);
    } finally {
      options.delete();
    }
    interpreter.allocateTensors();
    final input = interpreter.getInputTensor(0),
        output = interpreter.getOutputTensor(0);
    if (interpreter.getInputTensors().length != 1 ||
        interpreter.getOutputTensors().length != 1 ||
        input.shape.join(',') != '1,640,640,3' ||
        output.shape.join(',') != '1,6,8400' ||
        input.type != TensorType.float32 ||
        output.type != TensorType.float32) {
      throw StateError('지원하지 않는 모델 tensor 형식');
    }
    final load = watch.elapsedMicroseconds / 1000;
    watch.reset();
    input.setTo(Float32List(640 * 640 * 3).buffer.asUint8List());
    interpreter.invoke();
    args.$1.send({
      'ready': true,
      'load': load,
      'warm': watch.elapsedMicroseconds / 1000
    });
    await for (final message in port) {
      if (message == 'close') break;
      if (message is! VisionFrame) continue;
      try {
        watch.reset();
        final prepared = prepareFrame(message);
        input.setTo(prepared.tensor.buffer.asUint8List());
        final inference = Stopwatch()..start();
        interpreter.invoke();
        inference.stop();
        // Copy native output before another invocation or interpreter disposal.
        final bytes = Uint8List.fromList(output.data);
        final values = Float32List.view(bytes.buffer);
        final boxes = decodeBoxes(values, prepared);
        final jpeg =
            Uint8List.fromList(img.encodeJpg(prepared.image, quality: 75));
        args.$1.send(LocalObservation(
            message.metadata(),
            jpeg,
            boxes,
            prepared.image.width,
            prepared.image.height,
            inference.elapsedMicroseconds / 1000,
            watch.elapsedMicroseconds / 1000));
      } catch (_) {
        args.$1.send('프레임 변환 또는 TFLite 추론 실패');
      }
    }
  } catch (_) {
    args.$1.send('TFLite 모델/네이티브 런타임 초기화 실패');
  } finally {
    interpreter?.close();
    port.close();
    args.$1.send('closed');
  }
}

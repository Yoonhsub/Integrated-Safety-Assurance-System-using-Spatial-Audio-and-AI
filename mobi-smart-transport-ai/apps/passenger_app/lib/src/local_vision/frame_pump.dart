import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'package:flutter/foundation.dart';
import 'vision_codec.dart';

/// One in-flight inference and at most one replaceable pending frame.
class FramePump extends ChangeNotifier {
  FramePump(this.infer, this.nowMicros,
      {this.ttl = const Duration(seconds: 2), this.onResult});
  final Future<LocalObservation> Function(VisionFrame) infer;
  final int Function() nowMicros;
  final Duration ttl;
  final Future<void> Function(LocalObservation)? onResult;
  VisionFrame? _latest;
  bool active = false, _busy = false, _disposed = false;
  int _generation = 0;
  Completer<void>? _idle;
  Timer? _expiry;
  LocalObservation? observation;
  String? error;
  bool lost = false;
  int? _lastReceived, _lastSubmitted;
  int received = 0, processed = 0, replaced = 0, expired = 0, rejected = 0;

  void start() {
    if (_disposed || _busy) throw StateError('이전 추론이 종료되지 않았습니다.');
    _generation++;
    active = true;
    lost = false;
    _lastReceived = nowMicros();
    error = null;
    received = processed = replaced = expired = rejected = 0;
    _lastSubmitted = null;
    _expiry?.cancel();
    _expiry =
        Timer.periodic(const Duration(milliseconds: 100), (_) => expire());
  }

  void expire() {
    final nextLost = active &&
        _lastReceived != null &&
        nowMicros() - _lastReceived! >= ttl.inMicroseconds;
    if (lost != nextLost) {
      lost = nextLost;
      _notify();
    }
    final item = observation;
    if (item != null &&
        nowMicros() - item.frame.receivedMicros >= ttl.inMicroseconds) {
      observation = null;
      _notify();
    }
  }

  void submit(VisionFrame frame) {
    if (!active || _disposed) return;
    if (frame.receivedMicros < 0 ||
        frame.receivedMicros > nowMicros() ||
        (_lastSubmitted != null && frame.receivedMicros <= _lastSubmitted!)) {
      rejected++;
      return;
    }
    _lastSubmitted = frame.receivedMicros;
    _lastReceived = frame.receivedMicros;
    if (lost) {
      lost = false;
      _notify();
    }
    received++;
    if (_latest != null) replaced++;
    _latest = frame;
    if (!_busy) unawaited(_drain());
  }

  Future<void> _drain() async {
    _busy = true;
    _idle = Completer<void>();
    final generation = _generation;
    try {
      while (active && generation == _generation && _latest != null) {
        final frame = _latest!;
        _latest = null;
        if (nowMicros() - frame.receivedMicros >= ttl.inMicroseconds) {
          expired++;
          continue;
        }
        try {
          final value = await infer(frame);
          if (!active || generation != _generation) break;
          if (value.frame.frameId != frame.frameId ||
              value.frame.receivedMicros != frame.receivedMicros ||
              value.frame.receivedAt != frame.receivedAt) {
            throw StateError("프레임 식별 정보 불일치");
          }
          value.toDetectionResult();
          if (nowMicros() - frame.receivedMicros >= ttl.inMicroseconds) {
            expired++;
            observation = null;
          } else {
            await onResult?.call(value);
            if (!active || generation != _generation) break;
            if (nowMicros() - frame.receivedMicros >= ttl.inMicroseconds) {
              expired++;
              observation = null;
            } else {
              observation = value;
              processed++;
            }
          }
          _notify();
        } catch (failure) {
          if (active && generation == _generation) {
            error = failure is VisionProducerException
                ? failure.message
                : '모바일 추론 실패 · 카메라를 다시 시작해 주세요';
            active = false;
            observation = null;
            _latest = null;
            _expiry?.cancel();
            _notify();
          }
          break;
        }
      }
    } finally {
      _busy = false;
      _idle?.complete();
    }
  }

  Future<void> stop() async {
    active = false;
    _generation++;
    _latest = null;
    observation = null;
    _expiry?.cancel();
    _notify();
    await _idle?.future;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    active = false;
    _generation++;
    _latest = null;
    observation = null;
    _expiry?.cancel();
    super.dispose();
  }
}

class VisionProducerException implements Exception {
  const VisionProducerException(this.message, {this.expired = false});
  final String message;
  final bool expired;
  @override
  String toString() => message;
}

/// Local Preview transport. Reuses authenticated HTTP and a server-admin-issued
/// binding; a Passenger UID or source string is never a producer credential.
class DartVisionProducerClient {
  DartVisionProducerClient(
      {required String baseUrl,
      required this.producerUid,
      required this.authClient,
      required Map<String, dynamic> binding,
      this.diagnostic})
      : base = Uri.parse(baseUrl) {
    if (base.scheme != 'http' ||
        !{'127.0.0.1', 'localhost'}.contains(base.host) ||
        !base.hasPort ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment ||
        (base.path.isNotEmpty && base.path != '/')) {
      throw const VisionProducerException('로컬 Backend 주소를 확인해 주세요.');
    }
    if (binding['producerId'] != producerUid ||
        binding['sourceType'] != 'android_camera' ||
        !['bindingId', 'cameraEpoch', 'cameraId', 'sessionId'].every(
            (k) => binding[k] is String && (binding[k] as String).isNotEmpty)) {
      throw const VisionProducerException('승인된 Android 생산자 Binding이 필요합니다.');
    }
    _binding =
        Map<String, dynamic>.from(jsonDecode(jsonEncode(binding)) as Map);
  }
  final Uri base;
  final String producerUid;
  final AuthenticatedApiClient authClient;
  final void Function(Map<String, Object?>)? diagnostic;
  late final Map<String, dynamic> _binding;
  String get sessionId => _binding['sessionId'] as String;
  String get cameraId => _binding['cameraId'] as String;
  static final Map<String, Future<http.Response>> _flights = {};
  String? _pending;
  int _index = 0;
  Completer<void>? _abort;
  bool _closed = false;
  int submitted = 0;
  bool get hasPending => _pending != null;
  void cancel() {
    if (_abort?.isCompleted == false) _abort!.complete();
  }

  void close() {
    _closed = true;
    cancel();
  }

  Future<void> submit(LocalObservation observation) async {
    if (_closed) throw const VisionProducerException('Vision 전송이 종료되었습니다.');
    if (_pending != null) await retryPending();
    if (_closed) throw const VisionProducerException('Vision 전송이 종료되었습니다.');
    final result = observation.toDetectionResult();
    // Frame UUID is also the stable event UUID. Retrying never rebuilds body,
    // timestamps, frame index or event identity after an uncertain delivery.
    _pending = jsonEncode({
      for (final k in [
        'producerId',
        'cameraId',
        'sessionId',
        'bindingId',
        'cameraEpoch',
        'sourceType'
      ])
        k: _binding[k],
      'envelopeVersion': '2.0.0',
      'visionEventId': result['frameId'],
      'frameIndex': _index++,
      'capturedAt': result['capturedAt'],
      'captureClock': 'host_read',
      'detectionResult': result
    });
    await retryPending();
  }

  Future<void> retryPending({bool discardExpired = false}) async {
    if (_closed) throw const VisionProducerException('Vision 전송이 종료되었습니다.');
    final body = _pending;
    if (body == null) return;
    final key = '${base.origin}/$cameraId';
    if (_flights.containsKey(key)) {
      throw const VisionProducerException('이전 전송 종료 후 다시 시작해 주세요.');
    }
    final abort = Completer<void>();
    _abort = abort;
    final uri = base.resolve('/ai-vision/v2/events');
    final raw = authClient.post(uri,
        headers: {'Content-Type': 'application/json'},
        body: body,
        abortTrigger: abort.future);
    _flights[key] = raw;
    void finished() {
      if (identical(_flights[key], raw)) _flights.remove(key);
      if (identical(_abort, abort)) _abort = null;
    }

    unawaited(raw.then<void>((_) => finished(),
        onError: (Object _, StackTrace __) => finished()));
    try {
      final response =
          await raw.timeout(const Duration(seconds: 2), onTimeout: () {
        cancel();
        throw TimeoutException('Vision transport');
      });
      diagnostic?.call({
        'method': 'POST',
        'path': uri.path,
        'status': response.statusCode,
        'frameIndex': jsonDecode(body)['frameIndex']
      });
      if (response.statusCode == 202) {
        final receipt = jsonDecode(response.body);
        if (receipt is! Map ||
            receipt['visionEventId'] != jsonDecode(body)['visionEventId'] ||
            receipt['bindingId'] != _binding['bindingId'] ||
            receipt['guidanceEligible'] != false ||
            receipt['stored'] != false) {
          throw const VisionProducerException('Backend 전송 결과를 확인할 수 없습니다.');
        }
        if (_pending == body) _pending = null;
        submitted++;
        return;
      }
      if (response.statusCode == 409) {
        final value = jsonDecode(response.body);
        if (value is Map &&
            value['error'] is Map &&
            value['error']['message'] == 'Frame is too old') {
          _pending = null;
          if (!discardExpired) {
            throw const VisionProducerException(
                '프레임이 만료되었습니다. Vision을 다시 시작해 주세요.',
                expired: true);
          }
          return; // confirmed rejection: discard, never retimestamp
        }
      }
      if (response.statusCode >= 500) {
        throw const VisionProducerException(
            'Backend 연결 실패 · 서버 복구 후 다시 시작해 주세요.');
      }
      throw const VisionProducerException(
          'Backend가 결과를 거부했습니다. Binding과 세션을 확인해 주세요.');
    } on AuthenticatedApiException catch (error) {
      if (error.statusCode >= 500) {
        throw const VisionProducerException(
            'Backend 연결 실패 · 인증 서비스 또는 서버 복구 후 다시 시작해 주세요.');
      }
      throw const VisionProducerException('생산자 인증 또는 Binding 권한을 확인해 주세요.');
    } on VisionProducerException {
      rethrow;
    } catch (_) {
      throw const VisionProducerException(
          'Backend 연결 실패 · 서버를 확인한 뒤 다시 시작해 주세요.');
    }
  }
}

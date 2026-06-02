import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/app.dart';
import 'package:mobi_passenger_app/src/models/v3_guidance_models.dart';

void main() {
  test('MobiApp can be constructed', () {
    expect(const MobiApp(), isA<MobiApp>());
  });

  test('route recommendation keeps absent evidence nullable', () {
    final response = V3RouteRecommendResponse.fromJson(<String, dynamic>{
      'recommendations': <dynamic>[],
      'fallbackSource': 'ERROR',
      'usedGemini': false,
      'mapsGrounded': false,
      'mapsEvidence': <dynamic>[],
      'stopEvidence': null,
      'evidence': null,
    });

    expect(response.stopEvidence, isNull);
    expect(response.evidence, isNull);
  });

  test('route plan parses NO_ROUTE without a recommended plan', () {
    final response = V3RoutePlanResponse.fromJson(<String, dynamic>{
      'status': 'NO_ROUTE',
      'heardText': '없는 목적지',
      'plans': <dynamic>[],
      'recommendedPlan': null,
      'question': '현재 후보 정류장 조합으로 경로를 찾지 못했어.',
      'fallbackSource': 'MOCK',
    });

    expect(response.status, 'NO_ROUTE');
    expect(response.recommendedPlan, isNull);
    expect(response.question, isNotEmpty);
  });

  test('route plan parses destination choices and alternatives', () {
    final response = V3RoutePlanResponse.fromJson(<String, dynamic>{
      'status': 'NEEDS_CHOICE',
      'readiness': 'NEEDS_CHOICE',
      'heardText': '터미널',
      'destination': <String, dynamic>{
        'status': 'NEEDS_CHOICE',
        'candidates': <dynamic>[
          <String, dynamic>{
            'name': '청주고속버스터미널',
            'type': 'PLACE',
            'confidence': 0.8
          },
          <String, dynamic>{
            'name': '청주시외버스터미널',
            'type': 'PLACE',
            'confidence': 0.75
          },
        ],
      },
      'plans': <dynamic>[],
      'alternatives': <dynamic>[],
      'recommendedPlan': null,
      'fallbackSource': 'MOCK',
    });

    expect(response.readiness, 'NEEDS_CHOICE');
    expect(response.destination?.candidates.length, 2);
    expect(response.alternatives, isEmpty);
  });

  test('arrivals parse service status without inventing congestion', () {
    final response = V3BusArrivalsResponse.fromJson(<String, dynamic>{
      'stopId': 'mock-stop-001',
      'routeNo': '862',
      'arrivals': <dynamic>[
        <String, dynamic>{
          'routeNo': '862',
          'routeId': 'mock-route-862-to-fortress',
          'stopId': 'mock-stop-001',
          'arrivalMinutes': 7,
          'remainingStops': 3,
          'congestion': null,
        },
      ],
      'fallbackSource': 'MOCK',
      'serviceStatus': <String, dynamic>{
        'operatingNow': true,
        'reason': 'ARRIVALS_AVAILABLE',
        'message': '현재 도착 예정 버스가 확인됐어.',
        'scheduleSource': 'DEFAULT_FALLBACK',
      },
    });

    expect(response.serviceStatus?.reason, 'ARRIVALS_AVAILABLE');
    expect(response.arrivals.single.congestion, isNull);
  });

  test('live route status keeps unavailable bus positions empty', () {
    final response = V3LiveRouteStatusResponse.fromJson(<String, dynamic>{
      'routeNo': '862',
      'routeId': 'mock-route-862-to-fortress',
      'boardStopId': 'mock-stop-001',
      'alightStopId': 'seed-stop-sangdang-fortress',
      'markers': <dynamic>[
        <String, dynamic>{
          'type': 'USER',
          'label': '내 현재 위치',
          'latitude': 36.6359,
          'longitude': 127.4596,
        },
      ],
      'arrivals': <dynamic>[],
      'busPositions': <dynamic>[],
      'serviceStatus': <String, dynamic>{
        'operatingNow': true,
        'reason': 'ARRIVAL_INFO_UNAVAILABLE_WITHIN_SERVICE_WINDOW',
        'message': '현재 도착정보가 확인되지 않아.',
        'scheduleSource': 'DEFAULT_FALLBACK',
      },
      'warnings': <dynamic>['현재 버스 위치는 아직 조회되지 않았어.'],
      'updatedAt': '2026-06-02T00:00:00Z',
      'fallbackSource': 'MOCK',
    });

    expect(response.busPositions, isEmpty);
    expect(response.warnings.single, contains('버스 위치'));
    expect(response.serviceStatus.operatingNow, isTrue);
  });

  test('agent response keeps missing trace backward compatible', () {
    final response = V3AgentResponse.fromJson(<String, dynamic>{
      'sessionId': 'demo-session',
      'intent': 'WAKE_ONLY',
      'state': 'IDLE',
      'message': '응, 듣고 있어.',
      'ttsMode': 'LOCAL_TTS',
      'fallbackSource': 'MOCK',
    });

    expect(response.trace, isEmpty);
    expect(response.traceId, isNull);
  });

  test('agent response parses trace event details', () {
    final response = V3AgentResponse.fromJson(<String, dynamic>{
      'sessionId': 'demo-session',
      'intent': 'FIND_ROUTE',
      'state': 'WAITING_FOR_BUS',
      'message': '경로를 확인했어.',
      'ttsMode': 'LOCAL_TTS',
      'fallbackSource': 'MOCK',
      'traceId': 'trace-demo',
      'trace': <dynamic>[
        <String, dynamic>{
          'id': 'trace-demo:1',
          'step': 1,
          'type': 'NORMALIZE_UTTERANCE',
          'title': '발화 정리',
          'status': 'DONE',
          'summary': '요청 문장을 정리했어.',
          'provider': 'MOBI',
          'operation': 'normalize',
          'safePayload': <String, dynamic>{'wakeWordRemoved': true},
          'durationMs': 3,
        },
      ],
    });

    expect(response.traceId, 'trace-demo');
    expect(response.trace.single.type, 'NORMALIZE_UTTERANCE');
    expect(response.trace.single.durationMs, 3);
  });

  test('trace payload display sanitizer redacts secrets and precise location',
      () {
    final payload = sanitizeAgentTracePayloadForDisplay(<String, dynamic>{
      'apiKey': 'do-not-display',
      'Authorization': 'Bearer do-not-display',
      'requestUrl': 'https://example.com/path?token=do-not-display',
      'lat': 36.63591234,
      'lng': 127.45961234,
      'nested': <String, dynamic>{
        'value': 'abcdefghijklmnopqrstuvwxyz0123456789',
      },
    });

    expect(payload['apiKey'], '[REDACTED]');
    expect(payload['Authorization'], '[REDACTED]');
    expect(payload['requestUrl'], '[URL_REDACTED]');
    expect(payload['lat'], 36.6359);
    expect(payload['lng'], 127.4596);
    expect((payload['nested'] as Map<String, dynamic>)['value'], '[REDACTED]');
  });
}

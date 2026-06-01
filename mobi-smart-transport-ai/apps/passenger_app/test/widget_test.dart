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
          <String, dynamic>{'name': '청주고속버스터미널', 'type': 'PLACE', 'confidence': 0.8},
          <String, dynamic>{'name': '청주시외버스터미널', 'type': 'PLACE', 'confidence': 0.75},
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
}

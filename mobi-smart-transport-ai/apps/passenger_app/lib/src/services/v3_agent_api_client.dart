// V3 Agent API client
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/v3_guidance_models.dart';

class V3AgentApiClient {
  final String baseUrl;

  V3AgentApiClient({String? baseUrl})
      : baseUrl = baseUrl ??
            const String.fromEnvironment('MOBI_API_BASE_URL',
                defaultValue: 'http://127.0.0.1:8000');

  Future<GuidanceSession> createSession({
    String sessionId = 'demo-session-001',
    String? userId,
    String? wakeWord,
  }) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/guidance/session'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'sessionId': sessionId,
        if (userId != null) 'userId': userId,
        if (wakeWord != null) 'wakeWord': wakeWord,
      }),
    );
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    return GuidanceSession.fromJson(json);
  }

  Future<GuidanceSession> getState(String sessionId) async {
    final resp = await http.get(
      Uri.parse('$baseUrl/guidance/state?sessionId=$sessionId'),
    );
    return GuidanceSession.fromJson(
        jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<GuidanceSession> resetState(String sessionId) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/guidance/state/reset'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'sessionId': sessionId}),
    );
    return GuidanceSession.fromJson(
        jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<ConverseResponse> converse({
    required String sessionId,
    required String utterance,
    double? lat,
    double? lng,
  }) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/agent/converse'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'sessionId': sessionId,
        'utterance': utterance,
        if (lat != null) 'lat': lat,
        if (lng != null) 'lng': lng,
      }),
    );
    return ConverseResponse.fromJson(
        jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> mockGeofence({
    required String sessionId,
    required String mockStatus,
  }) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/mock/geofence'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'sessionId': sessionId, 'mockStatus': mockStatus}),
    );
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> mockBeacons({
    required String sessionId,
    required List<Map<String, dynamic>> beacons,
  }) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/mock/beacons'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'sessionId': sessionId, 'beacons': beacons}),
    );
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> mockBusEvent({
    required String sessionId,
    required String event,
  }) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/mock/bus-event'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'sessionId': sessionId, 'event': event}),
    );
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> boardingConfirm({
    required String sessionId,
    required bool boarded,
  }) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/guidance/boarding-confirm'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'sessionId': sessionId, 'boarded': boarded}),
    );
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }
}

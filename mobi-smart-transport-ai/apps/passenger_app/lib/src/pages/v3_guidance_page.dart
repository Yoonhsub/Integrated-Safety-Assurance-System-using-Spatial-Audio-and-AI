// V3 Guidance Page — placeholder
import 'package:flutter/material.dart';
import '../models/v3_guidance_models.dart';
import '../services/v3_agent_api_client.dart';
import '../widgets/debug_panel.dart';
import '../widgets/mock_control_panel.dart';
import '../widgets/quick_action_panel.dart';

class V3GuidancePage extends StatefulWidget {
  const V3GuidancePage({super.key});

  @override
  State<V3GuidancePage> createState() => _V3GuidancePageState();
}

class _V3GuidancePageState extends State<V3GuidancePage> {
  final _client = V3AgentApiClient();
  GuidanceSession? _session;
  String _lastMessage = '';
  String _sttResult = '';
  bool _showDebug = true;
  String? _geofenceStatus;
  String? _lastApi;

  static const _sessionId = 'demo-session-001';

  @override
  void initState() {
    super.initState();
    _initSession();
  }

  Future<void> _initSession() async {
    try {
      final s = await _client.createSession(sessionId: _sessionId);
      setState(() => _session = s);
    } catch (_) {}
  }

  Future<void> _handleUtterance(String utterance) async {
    setState(() => _sttResult = utterance);
    try {
      final resp = await _client.converse(
        sessionId: _sessionId,
        utterance: utterance,
        lat: 36.6282,
        lng: 127.4562,
      );
      setState(() {
        _lastMessage = resp.message;
        _lastApi = '/agent/converse';
      });
      _refreshSession();
    } catch (_) {
      setState(() {
        _lastMessage = '음성을 정확히 인식하지 못했습니다. 다시 말씀하시거나 화면 버튼을 선택해주세요.';
      });
    }
  }

  Future<void> _handleMockAction(String action) async {
    try {
      switch (action) {
        case 'ARRIVED_AT_STOP':
        case 'LEFT_WAITING_AREA':
        case 'DANGER_ZONE':
        case 'RETURNED_TO_STOP':
          final r = await _client.mockGeofence(sessionId: _sessionId, mockStatus: action);
          setState(() {
            _geofenceStatus = r['geofenceStatus'] as String?;
            _lastMessage = r['message'] as String? ?? '';
            _lastApi = '/mock/geofence';
          });
          break;
        case 'BUS1_NEAR':
          await _client.mockBeacons(sessionId: _sessionId, beacons: [
            {'busId': 'BUS_1', 'routeNo': '511', 'distanceLevel': 'near', 'rssi': -45, 'relativePosition': 'front'},
            {'busId': 'BUS_2', 'routeNo': '502', 'distanceLevel': 'mid', 'rssi': -63, 'relativePosition': 'rear'},
          ]);
          setState(() => _lastApi = '/mock/beacons');
          break;
        case 'BUS2_NEAR':
          await _client.mockBeacons(sessionId: _sessionId, beacons: [
            {'busId': 'BUS_2', 'routeNo': '502', 'distanceLevel': 'near', 'rssi': -50, 'relativePosition': 'front'},
          ]);
          setState(() => _lastApi = '/mock/beacons');
          break;
        case 'BUS2_FAR':
          await _client.mockBeacons(sessionId: _sessionId, beacons: [
            {'busId': 'BUS_2', 'routeNo': '502', 'distanceLevel': 'far', 'rssi': -80, 'relativePosition': 'rear'},
          ]);
          setState(() => _lastApi = '/mock/beacons');
          break;
        case 'BUS_PASSED':
          final r = await _client.mockBusEvent(sessionId: _sessionId, event: 'BUS_PASSED');
          setState(() {
            _lastMessage = r['message'] as String? ?? '';
            _lastApi = '/mock/bus-event';
          });
          break;
        case 'BOARDED':
          final r = await _client.boardingConfirm(sessionId: _sessionId, boarded: true);
          setState(() => _lastMessage = r['message'] as String? ?? '');
          break;
        case 'MISSED':
          final r = await _client.boardingConfirm(sessionId: _sessionId, boarded: false);
          setState(() => _lastMessage = r['message'] as String? ?? '');
          break;
        default:
          break;
      }
      _refreshSession();
    } catch (_) {}
  }

  Future<void> _reset() async {
    try {
      final s = await _client.resetState(_sessionId);
      setState(() {
        _session = s;
        _lastMessage = '';
        _sttResult = '';
        _geofenceStatus = null;
      });
    } catch (_) {}
  }

  Future<void> _refreshSession() async {
    try {
      final s = await _client.getState(_sessionId);
      setState(() => _session = s);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final s = _session;
    return Scaffold(
      appBar: AppBar(
        title: const Text('V3 버스 탑승 안내'),
        actions: [
          IconButton(
            icon: Icon(_showDebug ? Icons.bug_report : Icons.bug_report_outlined),
            onPressed: () => setState(() => _showDebug = !_showDebug),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _statusCard(s),
            const SizedBox(height: 8),
            Text('마지막 안내: $_lastMessage', style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 4),
            Text('STT: $_sttResult', style: const TextStyle(fontSize: 11, color: Colors.grey)),
            const Divider(),
            const Text('빠른 선택', style: TextStyle(fontWeight: FontWeight.bold)),
            QuickActionPanel(onUtterance: _handleUtterance, onReset: _reset),
            const Divider(),
            const Text('Mock Control', style: TextStyle(fontWeight: FontWeight.bold)),
            MockControlPanel(onAction: _handleMockAction),
            if (_showDebug) ...[
              const Divider(),
              DebugPanel(
                session: s,
                geofenceStatus: _geofenceStatus,
                lastApi: _lastApi,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _statusCard(GuidanceSession? s) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('상태: ${s?.guidanceState.name ?? '-'}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            Text('목적지: ${s?.destination ?? '-'}'),
            Text('정류장: ${s?.selectedStopName ?? '-'}'),
            Text('노선: ${s?.selectedRouteNo ?? '-'}번'),
            Text('도착 예정: ${s?.targetArrivalMinutes != null ? '${s!.targetArrivalMinutes}분 뒤' : '-'}'),
            Text('호출어: ${s?.wakeWord ?? '자비스'}'),
          ],
        ),
      ),
    );
  }
}

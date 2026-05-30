// V3 Guidance Page
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';
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
  final _tts = FlutterTts();
  final _stt = SpeechToText();

  GuidanceSession? _session;
  String _lastMessage = '';
  String _sttResult = '';
  bool _showDebug = true;
  bool _isListening = false;
  bool _sttReady = false;
  String? _geofenceStatus;
  String? _lastApi;

  static const _sessionId = 'demo-session-001';

  @override
  void initState() {
    super.initState();
    _initTts();
    _initStt();
    _initSession();
  }

  @override
  void dispose() {
    _tts.stop();
    _stt.stop();
    super.dispose();
  }

  Future<void> _initTts() async {
    await _tts.setLanguage('ko-KR');
    await _tts.setSpeechRate(0.5);
  }

  Future<void> _initStt() async {
    _sttReady = await _stt.initialize();
    setState(() {});
  }

  Future<void> _initSession() async {
    try {
      final s = await _client.createSession(sessionId: _sessionId);
      setState(() => _session = s);
    } catch (_) {}
  }

  Future<void> _speak(String text) async {
    await _tts.stop();
    await _tts.speak(text);
  }

  Future<void> _startListening() async {
    if (!_sttReady) {
      setState(() {
        _lastMessage = '음성을 정확히 인식하지 못했습니다. 다시 말씀하시거나 화면 버튼을 선택해주세요.';
      });
      return;
    }
    setState(() => _isListening = true);
    await _stt.listen(
      onResult: (result) {
        if (result.finalResult) {
          setState(() {
            _sttResult = result.recognizedWords;
            _isListening = false;
          });
          if (_sttResult.isNotEmpty) {
            _handleUtterance(_sttResult);
          }
        } else {
          setState(() => _sttResult = result.recognizedWords);
        }
      },
      localeId: 'ko-KR',
    );
  }

  Future<void> _stopListening() async {
    await _stt.stop();
    setState(() => _isListening = false);
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
      if (resp.shouldSpeak && resp.message.isNotEmpty) {
        await _speak(resp.message);
      }
      await _refreshSession();
    } catch (_) {
      const errMsg = '음성을 정확히 인식하지 못했습니다. 다시 말씀하시거나 화면 버튼을 선택해주세요.';
      setState(() => _lastMessage = errMsg);
      await _speak(errMsg);
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
          final msg = r['message'] as String? ?? '';
          setState(() {
            _geofenceStatus = r['geofenceStatus'] as String?;
            _lastMessage = msg;
            _lastApi = '/mock/geofence';
          });
          if (msg.isNotEmpty) await _speak(msg);
          break;
        case 'BUS1_NEAR':
          final r = await _client.mockBeacons(sessionId: _sessionId, beacons: [
            {'busId': 'BUS_1', 'routeNo': '511', 'distanceLevel': 'near', 'rssi': -45, 'relativePosition': 'front'},
            {'busId': 'BUS_2', 'routeNo': '502', 'distanceLevel': 'mid', 'rssi': -63, 'relativePosition': 'rear'},
          ]);
          final msg = r['message'] as String? ?? '';
          setState(() { _lastMessage = msg; _lastApi = '/mock/beacons'; });
          if (msg.isNotEmpty) await _speak(msg);
          break;
        case 'BUS2_NEAR':
          final r = await _client.mockBeacons(sessionId: _sessionId, beacons: [
            {'busId': 'BUS_2', 'routeNo': '502', 'distanceLevel': 'near', 'rssi': -50, 'relativePosition': 'front'},
          ]);
          final msg = r['message'] as String? ?? '';
          setState(() { _lastMessage = msg; _lastApi = '/mock/beacons'; });
          if (msg.isNotEmpty) await _speak(msg);
          break;
        case 'BUS2_FAR':
          await _client.mockBeacons(sessionId: _sessionId, beacons: [
            {'busId': 'BUS_2', 'routeNo': '502', 'distanceLevel': 'far', 'rssi': -80, 'relativePosition': 'rear'},
          ]);
          setState(() => _lastApi = '/mock/beacons');
          break;
        case 'BUS_PASSED':
          final r = await _client.mockBusEvent(sessionId: _sessionId, event: 'BUS_PASSED');
          final msg = r['message'] as String? ?? '';
          setState(() { _lastMessage = msg; _lastApi = '/mock/bus-event'; });
          if (msg.isNotEmpty) await _speak(msg);
          break;
        case 'BOARDED':
          final r = await _client.boardingConfirm(sessionId: _sessionId, boarded: true);
          final msg = r['message'] as String? ?? '';
          setState(() => _lastMessage = msg);
          if (msg.isNotEmpty) await _speak(msg);
          break;
        case 'MISSED':
          final r = await _client.boardingConfirm(sessionId: _sessionId, boarded: false);
          final msg = r['message'] as String? ?? '';
          setState(() => _lastMessage = msg);
          if (msg.isNotEmpty) await _speak(msg);
          break;
        default:
          break;
      }
      await _refreshSession();
    } catch (_) {}
  }

  Future<void> _reset() async {
    try {
      await _tts.stop();
      final s = await _client.resetState(_sessionId);
      setState(() {
        _session = s;
        _lastMessage = '';
        _sttResult = '';
        _geofenceStatus = null;
        _lastApi = null;
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
            tooltip: 'Debug Panel',
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
            _messageBox(),
            const SizedBox(height: 8),
            _voiceButton(),
            const Divider(),
            const Text('빠른 선택', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 4),
            QuickActionPanel(onUtterance: _handleUtterance, onReset: _reset),
            const Divider(),
            const Text('Mock Control', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 4),
            MockControlPanel(onAction: _handleMockAction),
            if (_showDebug) ...[
              const Divider(),
              DebugPanel(
                session: s,
                geofenceStatus: _geofenceStatus,
                lastApi: _lastApi,
              ),
            ],
            const SizedBox(height: 20),
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
            Text(
              '상태: ${s?.guidanceState.name ?? '-'}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            Text('목적지: ${s?.destination ?? '-'}'),
            Text('정류장: ${s?.selectedStopName ?? '-'}'),
            Text('노선: ${s?.selectedRouteNo != null ? '${s!.selectedRouteNo}번' : '-'}'),
            Text('도착 예정: ${s?.targetArrivalMinutes != null ? '${s!.targetArrivalMinutes}분 뒤' : '-'}'),
            Text('호출어: ${s?.wakeWord ?? '자비스'}'),
          ],
        ),
      ),
    );
  }

  Widget _messageBox() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.indigo[50],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('안내: $_lastMessage', style: const TextStyle(fontSize: 13)),
          if (_sttResult.isNotEmpty)
            Text('STT: $_sttResult', style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _voiceButton() {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton.icon(
        icon: Icon(_isListening ? Icons.stop : Icons.mic),
        label: Text(_isListening ? '듣는 중... (탭하여 중지)' : '음성 입력'),
        onPressed: _isListening ? _stopListening : _startListening,
        style: ElevatedButton.styleFrom(
          backgroundColor: _isListening ? Colors.red[400] : Colors.indigo,
          foregroundColor: Colors.white,
        ),
      ),
    );
  }
}

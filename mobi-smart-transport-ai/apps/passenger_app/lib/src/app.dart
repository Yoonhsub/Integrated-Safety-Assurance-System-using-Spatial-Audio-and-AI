import 'package:flutter/material.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'pages/agent_name_setup_page.dart';
import 'pages/data_mode_selection_page.dart';
import 'pages/home_page.dart';
import 'pages/v3_guidance_page.dart';
import 'pages/native_audio_page.dart';
import 'services/agent_name_store.dart';
import 'local_vision/local_vision_page.dart';
import 'pages/standalone_vision_page.dart';

class MobiApp extends StatefulWidget {
  const MobiApp(
      {super.key,
      this.firebaseConfigured = false,
      this.firebaseInitialization,
      this.onlineConfigurationIssue,
      this.authSession,
      this.authOnly = const AuthOnlyConfiguration.fromEnvironment()});

  final bool firebaseConfigured;
  final Future<bool>? firebaseInitialization;
  final String? onlineConfigurationIssue;
  final AuthSession? authSession;
  final AuthOnlyConfiguration authOnly;

  @override
  State<MobiApp> createState() => _MobiAppState();
}

class _MobiAppState extends State<MobiApp> {
  final AgentNameStore _agentNameStore = AgentNameStore();
  String? _agentName;
  bool _isLoadingAgentName = true;
  String? _selectedDataMode;
  bool _onlineSelected = false;
  late bool _firebaseReady;
  late bool _firebasePreparing;

  @override
  void initState() {
    super.initState();
    _firebaseReady = widget.firebaseConfigured;
    _firebasePreparing = widget.firebaseInitialization != null;
    final initialization = widget.firebaseInitialization;
    if (initialization != null) {
      initialization.then((ready) {
        if (mounted) {
          setState(() {
            _firebaseReady = ready;
            _firebasePreparing = false;
          });
        }
      }, onError: (Object _) {
        if (mounted) setState(() => _firebasePreparing = false);
      });
    }
    if (widget.authOnly.enabled) {
      _isLoadingAgentName = false;
    } else {
      _loadAgentName();
    }
  }

  Future<void> _loadAgentName() async {
    final agentName = await _agentNameStore.load();
    if (!mounted) return;
    setState(() {
      _agentName = agentName;
      _isLoadingAgentName = false;
    });
  }

  Future<void> _saveAgentName(String agentName) async {
    await _agentNameStore.save(agentName);
    if (!mounted) return;
    setState(() {
      _agentName = agentName.trim();
    });
  }

  Future<void> _resetAgentName() async {
    await _agentNameStore.clear();
    if (!mounted) return;
    setState(() {
      _agentName = null;
    });
  }

  void _onModeSelected(String mode) {
    setState(() {
      _selectedDataMode = mode;
    });
  }

  void _resetToModeSelection() {
    setState(() {
      _selectedDataMode = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.authOnly.enabled) {
      return AuthOnlyApp(
          configurationReady: _firebaseReady,
          configuration: widget.authOnly,
          requiredRole: 'passenger',
          appLabel: 'MOBI 승객 앱',
          session: widget.authSession);
    }
    final agentName = _agentName;
    final dataMode = _selectedDataMode;

    Widget home;
    if (_isLoadingAgentName) {
      home = const Scaffold(body: Center(child: CircularProgressIndicator()));
    } else if (dataMode == null) {
      home = DataModeSelectionPage(onModeSelected: _onModeSelected);
    } else if (agentName == null) {
      home = AgentNameSetupPage(onSaved: _saveAgentName);
    } else if (dataMode == 'live') {
      home = V3GuidancePage(
        agentName: agentName,
        onReturnToModeSelection: _resetToModeSelection,
        dataMode: dataMode,
      );
    } else {
      home = HomePage(
        agentName: agentName,
        onEditAgentName: _resetAgentName,
        onReturnToModeSelection: _resetToModeSelection,
        dataMode: dataMode,
      );
    }

    return MaterialApp(
      title: 'MOBI Passenger App',
      theme: ThemeData(useMaterial3: true),
      home: _onlineSelected
          ? Scaffold(
              appBar: AppBar(
                title: const Text('온라인 서비스'),
                leading: BackButton(
                    onPressed: () => setState(() => _onlineSelected = false)),
              ),
              body: widget.onlineConfigurationIssue != null
                  ? Center(
                      child: Text(
                          'UNAVAILABLE · ${widget.onlineConfigurationIssue}'))
                  : _firebasePreparing
                      ? const Center(child: CircularProgressIndicator())
                      : AuthGate(
                          configurationReady: _firebaseReady,
                          requiredRole: 'passenger',
                          session: widget.authSession,
                          appLabel: 'MOBI 승객 앱',
                          builder: (context, account) => home,
                        ),
            )
          : Scaffold(
              appBar: AppBar(title: const Text('MOBI Passenger')),
              body: Builder(
                  builder: (context) => ListView(
                        padding: const EdgeInsets.all(24),
                        children: [
                          const Text('사용할 기능을 선택해 주세요.'),
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            onPressed: () => Navigator.of(context)
                                .pushNamed('/standalone-vision'),
                            icon: const Icon(Icons.camera_alt_outlined),
                            label: const Text('로컬 시연 · 카메라와 음향'),
                          ),
                          const Text(
                              'LOCAL_DEMO · 로그인·PC·Backend 없이 휴대폰에서 실행합니다. 서버 전송과 안전 Guidance는 없습니다.'),
                          const SizedBox(height: 24),
                          OutlinedButton(
                            onPressed: () =>
                                setState(() => _onlineSelected = true),
                            child: const Text('온라인 서비스 · Firebase 로그인'),
                          ),
                          const Text(
                              '온라인 기능에는 인터넷과 Backend 연결이 필요합니다. USB 로컬 서버를 사용하는 경우 PC 연결이 필요합니다.'),
                        ],
                      )),
            ),
      routes: <String, WidgetBuilder>{
        '/standalone-vision': (_) => const StandaloneVisionPage(),
        '/native-audio': (_) => AuthGate(
              configurationReady: _firebaseReady,
              requiredRole: 'passenger',
              session: widget.authSession,
              appLabel: 'MOBI 승객 앱',
              builder: (context, account) => const NativeAudioPage(),
            ),
        '/local-vision': (_) => AuthGate(
              configurationReady: _firebaseReady,
              requiredRole: 'passenger',
              session: widget.authSession,
              appLabel: 'MOBI 승객 앱',
              builder: (context, account) => const LocalVisionPage(),
            ),
        '/v3-guidance': (_) => AuthGate(
              configurationReady: _firebaseReady,
              requiredRole: 'passenger',
              session: widget.authSession,
              appLabel: 'MOBI 승객 앱',
              builder: (context, account) => V3GuidancePage(
                agentName: agentName ?? '모비',
                onReturnToModeSelection: _resetToModeSelection,
                dataMode: dataMode ?? 'mock',
              ),
            ),
      },
    );
  }
}

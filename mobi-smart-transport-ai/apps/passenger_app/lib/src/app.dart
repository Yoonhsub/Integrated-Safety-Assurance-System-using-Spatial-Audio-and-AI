import 'package:flutter/foundation.dart';
import 'pages/passenger_presentation.dart';
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
import 'features/hardware_bus/hardware_bus_page.dart';

class MobiApp extends StatefulWidget {
  const MobiApp({
    super.key,
    this.firebaseConfigured = false,
    this.firebaseInitialization,
    this.onlineConfigurationIssue,
    this.authSession,
    this.authOnly = const AuthOnlyConfiguration.fromEnvironment(),
  });

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
      initialization.then(
        (ready) {
          if (mounted) {
            setState(() {
              _firebaseReady = ready;
              _firebasePreparing = false;
            });
          }
        },
        onError: (Object _) {
          if (mounted) setState(() => _firebasePreparing = false);
        },
      );
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
        session: widget.authSession,
      );
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

    final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    Widget protectAndroid(Widget child) {
      if (!android) return child;
      final issue = widget.onlineConfigurationIssue;
      if (issue != null) {
        return Scaffold(body: Center(child: Text('UNAVAILABLE · $issue')));
      }
      if (_firebasePreparing) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      return AuthGate(
        configurationReady: _firebaseReady,
        requiredRole: 'passenger',
        session: widget.authSession,
        appLabel: 'MOBI',
        builder: (context, account) => child,
      );
    }

    return MaterialApp(
      title: 'MOBI Passenger App',
      theme: passengerTheme(),
      home: _onlineSelected
          ? Scaffold(
              appBar: AppBar(
                title: const Text('온라인 서비스'),
                leading: BackButton(
                  onPressed: () => setState(() => _onlineSelected = false),
                ),
              ),
              body: widget.onlineConfigurationIssue != null
                  ? Center(
                      child: Text(
                        'UNAVAILABLE · ${widget.onlineConfigurationIssue}',
                      ),
                    )
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
          : protectAndroid(PassengerLanding(
              onOnline: () => setState(() => _onlineSelected = true))),
      routes: <String, WidgetBuilder>{
        // Local hardware diagnostics carry no server identity or Guidance authority.
        '/device-check': (_) => protectAndroid(const DeviceCheckPage()),
        '/hardware-bus': (_) => protectAndroid(const HardwareBusPage()),
        '/camera-bus-test': (_) =>
            protectAndroid(const HardwareBusPage(cameraIntegrated: true)),
        '/standalone-vision': (_) =>
            protectAndroid(const StandaloneVisionPage()),
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

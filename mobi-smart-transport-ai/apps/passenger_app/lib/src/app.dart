import 'package:flutter/material.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'pages/agent_name_setup_page.dart';
import 'pages/data_mode_selection_page.dart';
import 'pages/home_page.dart';
import 'pages/v3_guidance_page.dart';
import 'services/agent_name_store.dart';
import 'local_vision/local_vision_page.dart';

class MobiApp extends StatefulWidget {
  const MobiApp(
      {super.key,
      this.firebaseConfigured = false,
      this.authSession,
      this.authOnly = const AuthOnlyConfiguration.fromEnvironment()});

  final bool firebaseConfigured;
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

  @override
  void initState() {
    super.initState();
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
          configurationReady: widget.firebaseConfigured,
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
      home: AuthGate(
        configurationReady: widget.firebaseConfigured,
        requiredRole: 'passenger',
        session: widget.authSession,
        appLabel: 'MOBI 승객 앱',
        builder: (context, account) => home,
      ),
      routes: <String, WidgetBuilder>{
        '/local-vision': (_) => AuthGate(
              configurationReady: widget.firebaseConfigured,
              requiredRole: 'passenger',
              session: widget.authSession,
              appLabel: 'MOBI 승객 앱',
              builder: (context, account) => const LocalVisionPage(),
            ),
        '/v3-guidance': (_) => AuthGate(
              configurationReady: widget.firebaseConfigured,
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

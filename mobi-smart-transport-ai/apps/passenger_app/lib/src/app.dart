import 'package:flutter/material.dart';
import 'pages/agent_name_setup_page.dart';
import 'pages/home_page.dart';
import 'pages/v3_guidance_page.dart';
import 'services/agent_name_store.dart';

class MobiApp extends StatefulWidget {
  const MobiApp({super.key});

  @override
  State<MobiApp> createState() => _MobiAppState();
}

class _MobiAppState extends State<MobiApp> {
  final AgentNameStore _agentNameStore = AgentNameStore();
  String? _agentName;
  bool _isLoadingAgentName = true;

  @override
  void initState() {
    super.initState();
    _loadAgentName();
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

  @override
  Widget build(BuildContext context) {
    final agentName = _agentName;
    return MaterialApp(
      title: 'MOBI Passenger App',
      theme: ThemeData(useMaterial3: true),
      home: _isLoadingAgentName
          ? const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            )
          : agentName == null
              ? AgentNameSetupPage(onSaved: _saveAgentName)
              : HomePage(
                  agentName: agentName,
                  onEditAgentName: _resetAgentName,
                ),
      routes: <String, WidgetBuilder>{
        '/v3-guidance': (_) => V3GuidancePage(
              agentName: agentName ?? '모비',
            ),
      },
    );
  }
}

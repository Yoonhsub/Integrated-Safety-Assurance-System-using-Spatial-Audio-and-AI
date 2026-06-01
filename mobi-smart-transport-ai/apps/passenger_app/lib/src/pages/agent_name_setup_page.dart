import 'package:flutter/material.dart';

class AgentNameSetupPage extends StatefulWidget {
  const AgentNameSetupPage({
    super.key,
    required this.onSaved,
  });

  final Future<void> Function(String agentName) onSaved;

  @override
  State<AgentNameSetupPage> createState() => _AgentNameSetupPageState();
}

class _AgentNameSetupPageState extends State<AgentNameSetupPage> {
  final TextEditingController _controller = TextEditingController(text: '모비');
  bool _isSaving = false;
  String? _errorMessage;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final agentName = _controller.text.trim();
    if (agentName.isEmpty) {
      setState(() {
        _errorMessage = '에이전트 이름을 입력해 주세요.';
      });
      return;
    }
    if (agentName.length > 12) {
      setState(() {
        _errorMessage = '에이전트 이름은 12자 이하로 입력해 주세요.';
      });
      return;
    }

    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    await widget.onSaved(agentName);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.record_voice_over_outlined,
                size: 72,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 24),
              Text(
                '에이전트 이름을 정해 주세요',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 12),
              Text(
                '이후 이 이름을 부르면 버스 탑승 보조 에이전트가 응답합니다.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 28),
              TextField(
                controller: _controller,
                autofocus: true,
                enabled: !_isSaving,
                maxLength: 12,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: '에이전트 이름',
                  hintText: '예: 모비',
                  errorText: _errorMessage,
                ),
                onSubmitted: (_) => _isSaving ? null : _save(),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 60,
                child: FilledButton.icon(
                  onPressed: _isSaving ? null : _save,
                  icon: const Icon(Icons.check_circle_outline),
                  label: Text(_isSaving ? '저장 중...' : '이 이름으로 시작'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

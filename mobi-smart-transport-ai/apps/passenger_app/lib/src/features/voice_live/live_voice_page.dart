import 'dart:async';

import 'package:flutter/material.dart';

import 'aurora_voice_shader.dart';
import 'live_caption_controller.dart';
import 'live_caption_overlay.dart';
import 'live_voice_controller.dart';
import 'voice_turn_state.dart';

/// 전체 화면 Live 음성 대화 페이지.
/// 검은 배경 + 하단 오로라 + 자동 turn-taking(3초 무음) + 5줄 rolling 자막.
class LiveVoicePage extends StatefulWidget {
  const LiveVoicePage({
    super.key,
    required this.agentName,
    required this.processor,
    required this.speak,
    required this.stopAudio,
    required this.onExit,
  });

  final String agentName;
  final LiveUtteranceProcessor processor;
  final LiveSpeak speak;

  /// 진행 중인 Live TTS 재생/WebSocket을 즉시 중단한다(X·종료 시).
  final Future<void> Function() stopAudio;

  /// Live 세션 종료 시 호출. [navigated]이 true면 길 안내 동의로 인한 전환.
  final void Function(List<LiveCaptionLine> sessionLog,
      {required bool navigated}) onExit;

  @override
  State<LiveVoicePage> createState() => _LiveVoicePageState();
}

class _LiveVoicePageState extends State<LiveVoicePage> {
  late final LiveCaptionController _captions;
  late final LiveVoiceController _controller;
  bool _exiting = false;

  @override
  void initState() {
    super.initState();
    _captions = LiveCaptionController();
    _controller = LiveVoiceController(
      captions: _captions,
      processor: widget.processor,
      speak: widget.speak,
      stopAudio: widget.stopAudio,
      onNavigate: () => _exit(navigated: true),
      onEnd: () => _exit(navigated: false),
    );
    // iOS/인앱 브라우저는 AudioContext 시작이 사용자 제스처에서 멀어질수록
    // 조용히 suspend될 수 있어, route build 직후 곧바로 시작한다.
    unawaited(_controller.start());
  }

  Future<void> _exit({required bool navigated}) async {
    if (_exiting) return;
    _exiting = true;
    // 1) 남은 partial을 final로 정리해 로그 보존.
    _captions.flushTemporaryToSessionLog();
    final log = _captions.sessionLog;
    // 2) 진행 중인 Live TTS 재생/WebSocket 즉시 중단 + 마이크/STT/타이머 정리.
    //    정리가 길어지거나 멈춰도(iOS 오디오 컨텍스트/WS close 지연) 화면 전환이
    //    막히지 않도록 타임아웃을 둔다. (수십초 멈춰 X를 눌러야 했던 문제 방지)
    //    단, 길 안내 전환에서는 마지막 안내 음성을 끝까지 들려야 하므로 TTS는
    //    계속 재생하게 두고 마이크/STT만 정리한다.
    if (!navigated) {
      try {
        await widget.stopAudio().timeout(const Duration(milliseconds: 700));
      } catch (_) {}
    }
    try {
      await _controller.stop().timeout(const Duration(milliseconds: 700));
    } catch (_) {}
    // 3) 화면 임시 자막 제거.
    _captions.clearTemporary();
    // 4) 로그 전달(부모가 통합 대화 로그에 저장) + 네비 전환 여부 통지.
    widget.onExit(log, navigated: navigated);
    // 5) Live 페이지 종료.
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _captions.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exit(navigated: false);
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF05070C),
        body: Stack(
          fit: StackFit.expand,
          children: [
            // 하단 오로라(전체에 깔되 셰이더가 위쪽은 투명 처리).
            Positioned.fill(
              child: AuroraVoiceBackground(
                level: _controller.level,
                mode: _controller.shaderMode,
              ),
            ),
            // 상단 Live 상태.
            SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: ValueListenableBuilder<VoiceTurnState>(
                    valueListenable: _controller.state,
                    builder: (context, state, _) => _TopStatus(state: state),
                  ),
                ),
              ),
            ),
            // 자막(오로라 위쪽, 하단 컨트롤과 안 겹치게 padding).
            Positioned(
              left: 0,
              right: 0,
              bottom: 120,
              child: SafeArea(
                top: false,
                child: LiveCaptionOverlay(
                  controller: _captions,
                  agentName: widget.agentName,
                ),
              ),
            ),
            // 하단 컨트롤.
            Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 18),
                  child: _BottomControls(
                    onMicTap: () => _controller.handleMicTap(),
                    onClose: () => _exit(navigated: false),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopStatus extends StatelessWidget {
  const _TopStatus({required this.state});

  final VoiceTurnState state;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.graphic_eq, color: Colors.white, size: 20),
        const SizedBox(width: 8),
        const Text(
          'Live',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(width: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            state.statusLabel,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ),
      ],
    );
  }
}

class _BottomControls extends StatelessWidget {
  const _BottomControls({
    required this.onMicTap,
    required this.onClose,
  });

  final VoidCallback onMicTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          '잘 안 들리면 마이크를 탭해서 다시 말해줘',
          style: TextStyle(color: Colors.white60, fontSize: 12),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _RoundButton(
              icon: Icons.mic,
              background: Colors.white.withValues(alpha: 0.12),
              onTap: onMicTap,
            ),
            const SizedBox(width: 28),
            _RoundButton(
              icon: Icons.close,
              background: const Color(0xFFE53935),
              size: 64,
              onTap: onClose,
            ),
          ],
        ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.background,
    required this.onTap,
    this.size = 56,
  });

  final IconData icon;
  final Color background;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, color: Colors.white, size: size * 0.42),
        ),
      ),
    );
  }
}

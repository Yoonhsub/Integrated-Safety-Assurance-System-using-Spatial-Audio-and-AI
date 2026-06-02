import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 화면 하단 오로라 배경. FragmentShader를 1회 로드해 재사용하고,
/// Ticker로 time을 갱신하며 audioLevel/mode 리스너로만 repaint 한다(전체 rebuild 없음).
class AuroraVoiceBackground extends StatefulWidget {
  const AuroraVoiceBackground({
    super.key,
    required this.level,
    required this.mode,
  });

  /// 0.0~1.0 실제 오디오 RMS(또는 thinking pulse).
  final ValueListenable<double> level;

  /// 0 idle / 1 listening / 2 thinking / 3 speaking.
  final ValueListenable<double> mode;

  @override
  State<AuroraVoiceBackground> createState() => _AuroraVoiceBackgroundState();
}

class _AuroraVoiceBackgroundState extends State<AuroraVoiceBackground>
    with SingleTickerProviderStateMixin {
  ui.FragmentShader? _shader;
  late final Ticker _ticker;
  final ValueNotifier<double> _clock = ValueNotifier<double>(0.0);
  Duration _start = Duration.zero;

  @override
  void initState() {
    super.initState();
    _loadShader();
    _ticker = createTicker(_onTick)..start();
  }

  Future<void> _loadShader() async {
    try {
      final program =
          await ui.FragmentProgram.fromAsset('assets/shaders/voice_aurora.frag');
      if (!mounted) return;
      setState(() => _shader = program.fragmentShader());
    } catch (_) {
      // 셰이더 로드 실패 시 단색 그라데이션 폴백을 사용한다(빌드/렌더 안전).
    }
  }

  void _onTick(Duration elapsed) {
    if (_start == Duration.zero) _start = elapsed;
    _clock.value = (elapsed - _start).inMicroseconds / 1e6;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _clock.dispose();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shader = _shader;
    if (shader == null) {
      // 폴백: 셰이더가 아직/실패. 은은한 다운 그라데이션.
      return const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Color(0xFF1B3A66), Color(0xFF0A0E16), Colors.transparent],
            stops: [0.0, 0.5, 1.0],
          ),
        ),
      );
    }
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _AuroraPainter(
          shader: shader,
          clock: _clock,
          level: widget.level,
          mode: widget.mode,
        ),
      ),
    );
  }
}

class _AuroraPainter extends CustomPainter {
  _AuroraPainter({
    required this.shader,
    required this.clock,
    required this.level,
    required this.mode,
  }) : super(repaint: Listenable.merge([clock, level, mode]));

  final ui.FragmentShader shader;
  final ValueListenable<double> clock;
  final ValueListenable<double> level;
  final ValueListenable<double> mode;

  @override
  void paint(Canvas canvas, Size size) {
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, clock.value)
      ..setFloat(3, level.value.clamp(0.0, 1.0))
      ..setFloat(4, mode.value);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant _AuroraPainter oldDelegate) =>
      oldDelegate.shader != shader;
}

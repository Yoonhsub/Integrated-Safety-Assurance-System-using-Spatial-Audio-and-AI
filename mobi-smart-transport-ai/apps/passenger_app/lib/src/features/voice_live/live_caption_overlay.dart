import 'package:flutter/material.dart';

import 'live_caption_controller.dart';

/// 오로라 위쪽에 표시되는 5줄 rolling 자막.
/// 실제 렌더링 줄(TextPainter) 기준 최대 5줄만 보이고, 새 줄이 추가되면
/// 기존 줄은 위로 밀려 올라가며 맨 위 줄은 흐려진다. 터치는 통과시킨다.
class LiveCaptionOverlay extends StatelessWidget {
  const LiveCaptionOverlay({
    super.key,
    required this.controller,
    required this.agentName,
    this.maxVisibleLines = 5,
  });

  final LiveCaptionController controller;
  final String agentName;
  final int maxVisibleLines;

  static const TextStyle _lineStyle = TextStyle(
    color: Colors.white,
    fontSize: 32,
    height: 1.35,
    shadows: [Shadow(blurRadius: 6, color: Colors.black87)],
  );

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final lines = controller.visibleLines;
          if (lines.isEmpty) return const SizedBox.shrink();
          return LayoutBuilder(
            builder: (context, constraints) {
              final maxWidth = constraints.maxWidth;
              final visual = _toVisualLines(lines, maxWidth);
              final shown = visual.length > maxVisibleLines
                  ? visual.sublist(visual.length - maxVisibleLines)
                  : visual;
              return Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0x66000000)],
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOut,
                  alignment: Alignment.bottomCenter,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < shown.length; i++)
                        _AnimatedCaptionLine(
                          // 맨 위 줄(0)은 더 흐리게 → fade out 느낌.
                          key: ValueKey(shown[i].key),
                          line: shown[i],
                          topFade: i == 0 && visual.length > maxVisibleLines,
                        ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  List<_VisualLine> _toVisualLines(List<LiveCaptionLine> entries, double maxWidth) {
    final out = <_VisualLine>[];
    for (var e = 0; e < entries.length; e++) {
      final entry = entries[e];
      final prefix = switch (entry.speaker) {
        Speaker.user => '사용자: ',
        Speaker.thinking => '',
        Speaker.agent => '$agentName: ',
      };
      final full = '$prefix${entry.text}';
      final tp = TextPainter(
        text: TextSpan(text: full, style: _lineStyle),
        textDirection: TextDirection.ltr,
        maxLines: null,
      )..layout(maxWidth: maxWidth);
      final metrics = tp.computeLineMetrics();
      if (metrics.isEmpty) {
        out.add(_VisualLine(
          key: 'e$e-0-${entry.text.hashCode}',
          speaker: entry.speaker,
          text: full,
          isFinal: entry.isFinal,
        ));
        continue;
      }
      // 라인별 텍스트 경계를 위치로 추정해 분리한다.
      var start = 0;
      for (var l = 0; l < metrics.length; l++) {
        final line = metrics[l];
        final yMid = line.baseline - line.ascent / 2;
        final endPos = tp
            .getPositionForOffset(Offset(maxWidth, yMid))
            .offset
            .clamp(start, full.length);
        final segment = full.substring(start, endPos).trimRight();
        if (segment.isNotEmpty) {
          out.add(_VisualLine(
            key: 'e$e-$l-${segment.hashCode}',
            speaker: entry.speaker,
            text: segment,
            isFinal: entry.isFinal,
          ));
        }
        start = endPos;
      }
      if (start < full.length) {
        final tail = full.substring(start).trimRight();
        if (tail.isNotEmpty) {
          out.add(_VisualLine(
            key: 'e$e-tail-${tail.hashCode}',
            speaker: entry.speaker,
            text: tail,
            isFinal: entry.isFinal,
          ));
        }
      }
    }
    return out;
  }
}

class _VisualLine {
  const _VisualLine({
    required this.key,
    required this.speaker,
    required this.text,
    required this.isFinal,
  });

  final String key;
  final Speaker speaker;
  final String text;
  final bool isFinal;
}

class _AnimatedCaptionLine extends StatelessWidget {
  const _AnimatedCaptionLine({
    super.key,
    required this.line,
    required this.topFade,
  });

  final _VisualLine line;
  final bool topFade;

  @override
  Widget build(BuildContext context) {
    final baseOpacity = line.isFinal ? 0.95 : 0.62;
    final opacity = topFade ? baseOpacity * 0.35 : baseOpacity;
    return TweenAnimationBuilder<double>(
      // 새로 들어온 줄은 아래에서 위로 슬라이드 + 페이드 인.
      tween: Tween(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
      builder: (context, t, child) {
        return Opacity(
          opacity: (opacity * t).clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 10),
            child: child,
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(
          line.text,
          style: line.speaker == Speaker.thinking
              ? LiveCaptionOverlay._lineStyle.copyWith(
                  color: Colors.white60,
                  fontStyle: FontStyle.italic,
                  fontSize: 28,
                )
              : LiveCaptionOverlay._lineStyle,
        ),
      ),
    );
  }
}

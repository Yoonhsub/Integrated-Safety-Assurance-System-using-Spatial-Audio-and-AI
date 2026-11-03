import 'package:flutter/material.dart';
import '../services/vision_screen_audio.dart';

class VisionScreenAudioPanel extends StatelessWidget {
  const VisionScreenAudioPanel(
      {super.key, required this.audio, required this.cameraActive});
  final VisionScreenAudio audio;
  final bool cameraActive;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: audio,
      builder: (context, _) {
        final d = audio.diagnostic;
        return Card(
            child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SwitchListTile(
                          title: const Text('카메라 화면 위치 Cue + 음성 시연'),
                          subtitle:
                              const Text('정보성 시연 · 실제 3D 방향·거리·안전 Guidance 아님'),
                          value: audio.enabled,
                          onChanged: cameraActive ? audio.setEnabled : null),
                      Text(audio.status),
                      Wrap(spacing: 8, children: [
                        OutlinedButton(
                            onPressed: audio.stop,
                            child: const Text('화면 음향 STOP')),
                        OutlinedButton(
                            onPressed: audio.toggleHold,
                            child: Text(audio.holding
                                ? '화면 음향 Hold 해제'
                                : '화면 음향 Live Hold')),
                      ]),
                      const Text(
                          'LEFT/CENTER/RIGHT는 아래 검출 이미지의 가로 3등분입니다. 몸·목표 버스·출입문 방향을 뜻하지 않습니다.'),
                      Text(
                          '음향 승인 ${audio.admitted} · 완료 ${audio.completed} · 재생 중 프레임 제외 ${audio.skippedBusy}'),
                      if (d.isNotEmpty) ...[
                        Text('최근 음향 요청 frameId: ${d['frameId']}'),
                        Text('프레임 시각: ${d['capturedAt']}'),
                        Text(
                            '${d['className']} · confidence ${d['confidence']} · 화면 ${d['screenDirection']}'),
                        Text(
                            'bbox: ${d['bbox']} · 중심 x: ${d['screenCenterX']}'),
                        Text('${d['provenance']} · guidanceEligible=false'),
                      ]
                    ])));
      });
}

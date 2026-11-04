import 'package:flutter/material.dart';
import '../services/head_tracking_direction.dart';
import '../services/vision_screen_audio.dart';

class VisionScreenAudioPanel extends StatelessWidget {
  const VisionScreenAudioPanel({
    super.key,
    required this.audio,
    required this.cameraActive,
    this.showStopButton = true,
  });
  final VisionScreenAudio audio;
  final bool cameraActive;
  final bool showStopButton;

  Future<void> _recordMeasuredOffset(BuildContext context) async {
    final controller = TextEditingController();
    final value = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('실물 축 정렬 측정값'),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(
            signed: true,
            decimal: true,
          ),
          decoration: const InputDecoration(
            labelText: '카메라 축 오프셋 (도)',
            helperText: '실제 장착 축을 측정한 경우에만 입력',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () {
              final parsed = double.tryParse(controller.text.trim());
              if (parsed != null &&
                  parsed.isFinite &&
                  parsed.abs() <= 180) {
                Navigator.pop(context, parsed);
              }
            },
            child: const Text('측정 확인'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value != null) {
      audio.setMountAlignment(verified: true, cameraAxisOffsetDegrees: value);
    }
  }

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
                    title: const Text('화면 위치 소리·음성 안내'),
                    subtitle: const Text('정보성 시연 · 실제 3D 방향·거리·안전 Guidance 아님'),
                    value: audio.enabled,
                    onChanged: cameraActive ? audio.setEnabled : null,
                  ),
                  Text(audio.status),
                  DropdownButtonFormField<HeadTrackingCameraMount>(
                    decoration: const InputDecoration(labelText: '카메라 장착 방식'),
                    initialValue: audio.mountCalibration.mount,
                    items: const [
                      DropdownMenuItem(
                        value: HeadTrackingCameraMount.unverified,
                        child: Text('UNVERIFIED'),
                      ),
                      DropdownMenuItem(
                        value: HeadTrackingCameraMount.fixedWorldCamera,
                        child: Text('FIXED_WORLD_CAMERA'),
                      ),
                      DropdownMenuItem(
                        value: HeadTrackingCameraMount.headMountedCamera,
                        child: Text('HEAD_MOUNTED_CAMERA'),
                      ),
                      DropdownMenuItem(
                        value: HeadTrackingCameraMount.handheldPhone,
                        child: Text('HANDHELD_PHONE'),
                      ),
                    ],
                    onChanged: cameraActive
                        ? (value) {
                            if (value != null) {
                              audio.setHeadTrackingMount(value);
                            }
                          }
                        : null,
                  ),
                  ListTile(
                    title: const Text('실물 축 정렬·오프셋'),
                    subtitle: Text(
                      audio.mountCalibration.verified
                          ? '측정 확인됨 · ${audio.mountCalibration.cameraAxisOffsetDegrees!.toStringAsFixed(1)}°'
                          : '장착 선택만으로 활성화되지 않음 · NOT_VERIFIED',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (audio.mountCalibration.verified)
                          IconButton(
                            tooltip: '측정 확인 취소',
                            onPressed: () =>
                                audio.setMountAlignment(verified: false),
                            icon: const Icon(Icons.clear),
                          ),
                        IconButton(
                          tooltip: '실제 측정값 입력',
                          onPressed: cameraActive &&
                                  audio.mountCalibration.supportsHeadTrackedCue
                              ? () => _recordMeasuredOffset(context)
                              : null,
                          icon: const Icon(Icons.straighten),
                        ),
                      ],
                    ),
                  ),
                  CheckboxListTile(
                    title: const Text('Head Tracking HRTF 핑'),
                    subtitle: Text(
                      audio.hasCameraCalibration
                          ? '기본 OFF · 장착/축 정렬/FOV/READY/정면 보정 모두 필요'
                          : '카메라 수평 화각 미확인 · 화면 기준 Cue 유지',
                    ),
                    value: audio.headTrackingEnabled,
                    onChanged: cameraActive
                        ? (value) =>
                            audio.setHeadTrackingEnabled(value ?? false)
                        : null,
                  ),
                  Text(
                    '센서: ${audio.headTrackingSnapshot.status.name} · 원본 ${audio.headTrackingSnapshot.rawYaw?.toStringAsFixed(1) ?? '-'}° · 필터 ${audio.headTrackingSnapshot.filteredYaw?.toStringAsFixed(1) ?? '-'}° · 기준 ${audio.headTrackingSnapshot.referenceYaw?.toStringAsFixed(1) ?? '-'}°',
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      if (showStopButton)
                        OutlinedButton(
                          onPressed: audio.stop,
                          child: const Text('화면 음향 STOP'),
                        ),
                      OutlinedButton(
                        onPressed: audio.toggleHold,
                        child: Text(
                          audio.holding ? '화면 음향 Hold 해제' : '화면 음향 Live Hold',
                        ),
                      ),
                    ],
                  ),
                  const Text(
                    'LEFT/CENTER/RIGHT는 아래 검출 이미지의 가로 3등분입니다. 몸·목표 버스·출입문 방향을 뜻하지 않습니다.',
                  ),
                  ExpansionTile(
                    title: const Text('음향 상세 정보'),
                    maintainState: true,
                    children: [
                      Text(
                        '음향 승인 ${audio.admitted} · 완료 ${audio.completed} · 재생 중 프레임 제외 ${audio.skippedBusy}',
                      ),
                      if (d.isNotEmpty) ...[
                        Text('최근 음향 요청 frameId: ${d['frameId']}'),
                        Text('프레임 시각: ${d['capturedAt']}'),
                        Text(
                          '${d['className']} · confidence ${d['confidence']} · 화면 ${d['screenDirection']}',
                        ),
                        Text(
                            'bbox: ${d['bbox']} · 중심 x: ${d['screenCenterX']}'),
                        if (d['cameraAngleDegrees'] != null)
                          Text(
                            '카메라 각 ${d['cameraAngleDegrees']}° · 보정 각 ${d['correctedAngleDegrees']}°',
                          ),
                        Text('${d['provenance']} · guidanceEligible=false'),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      );
}

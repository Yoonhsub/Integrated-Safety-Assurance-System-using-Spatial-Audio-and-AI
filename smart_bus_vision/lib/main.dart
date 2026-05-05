import 'package:flutter/material.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SmartBusVisionApp());
}

class SmartBusVisionApp extends StatelessWidget {
  const SmartBusVisionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Smart Bus Vision',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const LiveDetectionPage(),
    );
  }
}

class LiveDetectionPage extends StatefulWidget {
  const LiveDetectionPage({super.key});

  @override
  State<LiveDetectionPage> createState() => _LiveDetectionPageState();
}

class _LiveDetectionPageState extends State<LiveDetectionPage> {
  final YOLOViewController controller = YOLOViewController();

  String guideText = '카메라를 정류장 전방으로 향해주세요.';
  String detectedText = '탐지 대기 중';
  double fps = 0.0;

  DateTime _lastGuideUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  // 현재 COCO 기반 사전학습 모델에서 우선 위험 후보로 볼 클래스들
  final Set<String> riskClasses = {
    'person',
    'bus',
    'car',
    'truck',
    'bicycle',
    'motorcycle',
  };

  void _handleResults(List<YOLOResult> results) {
    // 안내가 너무 자주 바뀌면 사용자가 혼란스러우므로 0.7초 정도로 제한
    final now = DateTime.now();
    if (now.difference(_lastGuideUpdate).inMilliseconds < 700) {
      return;
    }
    _lastGuideUpdate = now;

    final riskResults = results.where((result) {
      final className = result.className.toLowerCase();
      return result.confidence >= 0.35 && riskClasses.contains(className);
    }).toList();

    if (riskResults.isEmpty) {
      setState(() {
        guideText = '전방에 뚜렷한 장애물은 감지되지 않았습니다. 그래도 주의하세요.';
        detectedText = '위험 후보 없음';
      });
      return;
    }

    // 화면 아래쪽에 가까울수록 사용자와 가까운 물체라고 단순 추정
    riskResults.sort(
      (a, b) => b.normalizedBox.bottom.compareTo(a.normalizedBox.bottom),
    );

    final nearest = riskResults.first;
    final centerX = nearest.normalizedBox.center.dx;
    final bottomY = nearest.normalizedBox.bottom;

    final direction = _getDirection(centerX);
    final distance = _getDistanceLevel(bottomY);

    setState(() {
      guideText = '$direction $distance에 이동을 방해할 수 있는 물체가 있습니다.';
      detectedText = riskResults
          .take(3)
          .map(
            (r) => '${r.className} ${(r.confidence * 100).toStringAsFixed(0)}%',
          )
          .join(' / ');
    });
  }

  String _getDirection(double centerX) {
    if (centerX < 0.33) {
      return '왼쪽 전방';
    } else if (centerX < 0.66) {
      return '중앙 전방';
    } else {
      return '오른쪽 전방';
    }
  }

  String _getDistanceLevel(double bottomY) {
    if (bottomY > 0.75) {
      return '가까운 곳';
    } else if (bottomY > 0.50) {
      return '중간 거리';
    } else {
      return '먼 거리';
    }
  }

  @override
  Widget build(BuildContext context) {
    const modelId =
        'https://github.com/ultralytics/yolo-flutter-app/releases/download/v0.2.0/yolo26n_int8.tflite';

    return Scaffold(
      appBar: AppBar(title: const Text('Smart Bus Vision PoC')),
      body: Stack(
        children: [
          YOLOView(
            modelPath: modelId,
            controller: controller,
            onResult: _handleResults,
            onPerformanceMetrics: (metrics) {
              setState(() {
                fps = metrics.fps;
              });
            },
          ),

          // 하단 안내 패널
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    guideText,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '탐지: $detectedText',
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'FPS: ${fps.toStringAsFixed(1)}',
                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

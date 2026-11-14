import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/unsupported_concurrent_hardware_test_page.dart';

void main() {
  testWidgets('unsupported hardware entry is informational only',
      (tester) async {
    await tester
        .pumpWidget(const MaterialApp(home: ConcurrentHardwareTestPage()));
    expect(find.textContaining('Android 앱에서 지원'), findsOneWidget);
    expect(find.textContaining('시작하지 않습니다'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

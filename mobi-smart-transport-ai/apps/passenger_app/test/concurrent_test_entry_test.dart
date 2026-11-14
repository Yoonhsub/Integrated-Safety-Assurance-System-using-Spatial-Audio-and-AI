import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/pages/passenger_presentation.dart';

void main() {
  testWidgets('hardware diagnostics entry is outside the two-action home',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      home: const DeviceCheckPage(),
      routes: {
        '/concurrent-hardware-test': (_) => const Scaffold(
              body: Text('concurrent destination'),
            ),
      },
    ));
    const label = '동시 기기 테스트 (임시)';
    await tester.ensureVisible(find.text(label));
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
    expect(find.text('concurrent destination'), findsOneWidget);
    Navigator.of(tester.element(find.text('concurrent destination'))).pop();
    await tester.pumpAndSettle();
    expect(find.text(label), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}

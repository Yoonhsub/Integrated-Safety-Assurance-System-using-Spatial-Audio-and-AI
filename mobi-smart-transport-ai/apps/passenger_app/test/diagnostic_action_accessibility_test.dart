import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/diagnostic_action_hint.dart';

void main() {
  testWidgets('diagnostic hint keeps the original button action and label', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var activations = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: DiagnosticActionHint(
        hint: 'This diagnostic action runs as labeled.',
        child: FilledButton(
          key: const ValueKey('diagnostic-action'),
          onPressed: () => activations++,
          child: const Text('Start check'),
        ),
      )),
    ));
    final node =
        tester.getSemantics(find.byKey(const ValueKey('diagnostic-action')));
    expect(node.getSemanticsData().label, 'Start check');
    expect(node.getSemanticsData().hint,
        'This diagnostic action runs as labeled.');
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    expect(find.bySemanticsLabel('Start check'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('diagnostic-action')));
    expect(activations, 1);
    semantics.dispose();
  });
}

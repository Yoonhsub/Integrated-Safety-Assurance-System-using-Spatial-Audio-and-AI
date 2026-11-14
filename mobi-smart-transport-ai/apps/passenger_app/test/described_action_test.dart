import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/widgets/described_action.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';

class Voice implements SpeechEngine {
  final spoken = <String>[];
  @override
  Future<void> prepare({required bool requireKoreanVoice}) async {}
  @override
  Future<void> speak(String text) async {
    spoken.add(text);
  }

  @override
  Future<void> stop() async {}
}

void main() {
  for (final scenario in [
    'double',
    'expired',
    'different',
    'semantic',
    'talkback',
    'stop',
    'disabled',
    'background'
  ]) {
    testWidgets('functional action: $scenario', (t) async {
      final voice = Voice();
      final coordinator = SpeechPriorityCoordinator(voice);
      var runs = 0, stops = 0;
      final semantics = t.ensureSemantics();
      await t.pumpWidget(MaterialApp(
          home: MediaQuery(
              data:
                  MediaQueryData(accessibleNavigation: scenario == 'talkback'),
              child: ActionSpeechScope(
                  speech: coordinator,
                  child: Scaffold(
                      body: Column(children: [
                    for (final label in ['카메라 시작', '질문 전송', '음성 중지'])
                      DescribedAction.button(
                          label: label,
                          description: '$label 설명',
                          immediate: label == '음성 중지',
                          child: FilledButton(
                              onPressed: scenario == 'disabled'
                                  ? null
                                  : () {
                                      if (label == '음성 중지') {
                                        stops++;
                                      } else {
                                        runs++;
                                      }
                                    },
                              child: Text(label))),
                  ]))))));
      if (scenario == 'semantic') {
        final node = find.byWidgetPredicate(
            (w) => w is Semantics && w.properties.label == '카메라 시작');
        t.widget<Semantics>(node).properties.onTap!();
        await t.pump();
        expect(runs, 1);
        expect(voice.spoken, isEmpty);
      } else {
        await t.tapAt(t.getCenter(find.text('카메라 시작')));
        await t.pump();
        if (scenario == 'talkback') {
          expect(runs, 1);
          expect(voice.spoken, isEmpty);
        } else if (scenario == 'disabled') {
          expect(runs, 0);
          expect(voice.spoken, isEmpty);
        } else {
          expect(runs, 0);
          expect(voice.spoken, ['카메라 시작 설명']);
          if (scenario == 'expired') {
            await t.pump(const Duration(milliseconds: 501));
          }
          if (scenario == 'different') {
            await t.tapAt(t.getCenter(find.text('질문 전송')));
            await t.pump();
          }
          if (scenario == 'stop') {
            await t.tapAt(t.getCenter(find.text('음성 중지')));
            expect(stops, 1);
            await t.pump();
          }
          if (scenario == 'background') {
            t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
            t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          }
          await t.tapAt(t.getCenter(find.text('카메라 시작')));
          await t.pump();
          expect(runs, scenario == 'double' ? 1 : 0);
        }
      }
      await t.pumpWidget(const SizedBox());
      await t.pump();
      coordinator.dispose();
      semantics.dispose();
    });
  }
}

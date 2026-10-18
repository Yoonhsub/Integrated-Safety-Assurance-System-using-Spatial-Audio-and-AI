// Compile with dart compile js; execute using web_live_adapter_test.cjs.
// Uses the real Dart Web adapter with deterministic browser objects.
import 'dart:async';
import 'dart:js_interop';
import 'package:mobi_passenger_app/src/services/live_audio_player_web.dart';
import 'package:mobi_passenger_app/src/services/speech_engine.dart';

@JS('adapterProbe')
external void probe(JSString command);
Future<void> turn() => Future<void>.delayed(Duration.zero);
void check(bool valid, String label) {
  if (!valid) throw StateError(label);
}

Future<void> cancelled(Future<void> pending) async {
  try {
    await pending;
    throw StateError('cancellation missing');
  } on SpeechCancelled {
    return;
  }
}

Future<void> main() async {
  try {
    final player = LiveAudioPlayer();
    final old = cancelled(player.play(baseUrl: 'http://local', text: 'old'));
    await player.stop();
    await old;
    probe('noSocket'.toJS);
    probe('pass'.toJS);

    final connecting =
        cancelled(player.play(baseUrl: 'http://local', text: 'connecting'));
    await turn();
    await player.stop();
    await connecting;
    probe('lateSocketEvents'.toJS);
    probe('noPcm'.toJS);
    probe('pass'.toJS);

    final beforeFeed = cancelled(player.play(
        baseUrl: 'http://local',
        text: 'beforeFeed',
        onFirstAudio: () {
          unawaited(player.stop());
        }));
    await turn();
    probe('audio'.toJS);
    await beforeFeed;
    probe('noPcm'.toJS);
    probe('pass'.toJS);

    final valid = player.play(baseUrl: 'http://local', text: 'new');
    await turn();
    probe('openAudioDone'.toJS);
    await valid;
    check(player.state == LiveAudioState.completed, 'normal completion');
    probe('onePcm'.toJS);
    probe('pass'.toJS);
    await player.dispose();
    probe('success'.toJS);
  } catch (error) {
    probe('failure: $error'.toJS);
  }
}

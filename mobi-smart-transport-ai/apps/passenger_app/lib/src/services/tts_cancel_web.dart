import 'dart:js_interop';

// flutter_tts 4.2.5 Web stop may skip a queued utterance before onStart.
// Called only by the serialized, owner-checked coordinator.
@JS('speechSynthesis.cancel')
external void _cancel();
void cancelBrowserSpeech() {
  try {
    _cancel();
  } catch (_) {/* Web engine absent: normal TTS fails closed. */}
}

@JS('speechSynthesis.speaking')
external bool get _speaking;
@JS('speechSynthesis.pending')
external bool get _pending;
bool browserSpeechStillActive() {
  try {
    return _speaking || _pending;
  } catch (_) {
    return false;
  }
}

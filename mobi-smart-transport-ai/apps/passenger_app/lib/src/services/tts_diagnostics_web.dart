import 'dart:convert';
import 'dart:js_interop';
import 'package:web/web.dart' as web;

extension type _TtsProbe(JSObject _) implements JSObject {
  external JSString snapshot();
}
extension type _ProbeWindow(JSObject _) implements JSObject {
  @JS('MobiTts')
  external _TtsProbe? get tts;
}
Map<String, dynamic> readTtsDiagnostics() {
  try {
    final probe = _ProbeWindow(web.window).tts;
    if (probe == null) {
      return const {'supported': false, 'phase': 'adapter_missing'};
    }
    return Map<String, dynamic>.from(
        jsonDecode(probe.snapshot().toDart) as Map);
  } catch (_) {
    return const {'supported': false, 'phase': 'probe_failed'};
  }
}

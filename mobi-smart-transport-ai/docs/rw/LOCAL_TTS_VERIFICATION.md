# Local real TTS verification (explicit debug entry)

This entry is never imported by normal main.dart. It requires kDebugMode, web,
localhost/127.0.0.1 and MOBI_LOCAL_TTS_VERIFICATION=true before constructing any
fake auth or network clients. Release/profile, absent flag or remote hosting fails
closed. Fake tokens target only the hard-coded localhost:8280 test Backend.
No Firebase Auth initialization, ADC, IAM or real data run is used.

## Reproduction

Run scripts/build_local_tts_verification.ps1 -OutputPath <new directory outside repo>
from Windows with Flutter on PATH. It uses --no-pub and bundles local Malgun font
and CanvasKit. It never downloads voices or fonts, never starts speech, and never
overwrites existing evidence. Serve the resulting directory on localhost:5280.
The isolated Backend fixture runner used for this work is retained outside Git
in the accompanying tts-runtime-20261028 evidence directory.

## Existing architecture reused

- Chrome: BrowserSpeechEngine → web/mobi_tts.js → native Web Speech synthesis.
- Android/native Windows: existing FlutterSpeechEngine/flutter_tts implementation;
  declared platform support does not mean current physical-device validation.
- Guidance: existing session polling/ownership/cursor/TTL/dedup receiver.
- Live Hold: existing AudioHapticCueService.speakLocal and SpeechPriorityCoordinator.
- Fake SpeechEngine tests remain separate from the real BrowserSpeechEngine.
- Spatial/head tracking adapters are not invoked or changed by this verification.

The JS adapter now prefers an installed local Korean voice, retaining its previous
Korean fallback for normal callers. The debug UI refuses to arm without a local
Korean voice, so this verification does not use remote synthesis. Its snapshot
reports request/start/completion/cancellation/stop-confirmed states and native
speaking/pending flags. The bounded diagnostic event list contains no utterance
text, password or token. Late callbacks of retired utterances cannot overwrite
the current run diagnostics. Engine completion is distinct from audible output.

## Explicit manual sequence

Nothing speaks on startup. Press1 to play exactly '테스트 음성 출력입니다.'.
Then explicitly enable the session voice switch and press2 for a known MOCK
bus_door_visible/info/0.71 fixture. It is submitted to actual local /ai-vision/events
and delivered through the real session receiver. Audible text is labelled synthetic.
No actual door detection, geometry, boarding permission or walking safety is claimed.

While info is playing, press3. The actual local /agent/converse response must be
SAFETY_LOCAL/usedGemini=false; its verification-labelled Hold uses the existing
priority lease to stop the low-priority engine run before starting. Press4 to
retire the UI/auth epoch, remove the receiver, stop speech and prevent old callbacks
from affecting another session. 'Same UID login' also invalidates the epoch before
starting a new local session; it never performs real Firebase login. No old event
or voice is replayed automatically. New session audio needs another explicit1 click.

Stop or engine failures display AUDIO_BLOCKED and disable new audio until reload.
Unconfirmed stop is not treated as completed cancellation. Existing coordinator
quarantine/error handling is reused; no second TTS engine or parallel audio queue
was added. Duplicate manual/Hold requests are disabled while in flight. The
receiver's event/meaning dedup is unchanged; global identical-Hold-text dedup is
not newly claimed. No voice recording is performed. A local Backend/fixture failure before playback
is logged as LIVE_HOLD_BACKEND_FAILED and does not quarantine a healthy engine.
The external fixture harness must apply its localhost-only CORS middleware outside
the fixture authentication middleware, including OPTIONS handling. This does not
change production Backend CORS or authorization.

## Platform and validation limits

The OS default audio device routes output. Bone-conduction headphones work only
if the OS routes to that connected device; no spatial coordinates or special
headphone routing is synthesized. Device names cannot prove physical audibility.
Android and headphones are NOT_VERIFIED unless actually connected and tested.

Unit/VM tests use fake native engines/windows to verify errors, stop failure,
callback loss, stale callbacks, epochs and disposal. Real Chrome native start/end/
stop state is recorded separately. Without fresh human listening confirmation,
AUDIBLE_OUTPUT_NOT_VERIFIED remains the result regardless of callback success.

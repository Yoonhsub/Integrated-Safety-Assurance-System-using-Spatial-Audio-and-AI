# Local Spatial Audio verification

This explicit debug-only localhost entry never initializes Firebase, auth, a
Backend session or sensors. It is not imported by normal main.dart. Missing
MOBI_LOCAL_SPATIAL_VERIFICATION, release/profile, non-Web or non-loopback hosting
fails before construction. Normal index.html never enables the test graph.

## Existing structure and boundary

- SpatialCueService/MobiSpatialCue: implemented stereo beep and decoded clip graph;
  legacy cue stop clears its timer but does not track short tones. This verification
  does not claim those legacy tones have the stricter test graph shutdown contract.
- BrowserSpeechEngine/MobiTts: implemented Web Speech TTS; unchanged in this task.
- SpeechPriorityCoordinator/AudioHapticCueService: implemented cancellation,
  priority leases and fail-closed output quarantine; reused by this page.
- Native spatial adapter: partial/no directional output; not tested here.
- HeadTrackingDebugSnapshot: mock values, not physical head tracking.

The Web Speech synthesis interface exposes no standard PCM/AudioNode output.
Classification: ALTERNATE_AUDIO_SOURCE_REQUIRED. Current Microsoft Heami output
is NOT spatialized. A future voice-buffer adapter would need a local PCM/decoded
AudioBuffer with sample rate/channel metadata, cancellation and completion, source
provenance and session/epoch guards; no external voice API is added.
Reference: https://webaudio.github.io/web-speech-api/#speechsynthesisutterance
Web Audio: https://www.w3.org/TR/webaudio-1.1/

## Graph and coordinates

Reuses the existing MobiSpatialCue AudioContext through a localhost, explicit
verification flag. It does not create a competing context. The verification mode
omits the legacy global gesture/keeper handlers. Context resume is requested only
by explicit buttons; no sound at startup. No fetch/recording/microphone is used.
Each request creates a new one-shot mono AudioBufferSourceNode with deterministic
4-second 440/880Hz plus seeded noise, GainNode (0.12 envelope) and either
StereoPannerNode or HRTF PannerNode. Nothing is inferred from YOLO or an image.

Stereo LEFT=-1/CENTER=0/RIGHT=+1. Listener origin=(0,0,0), forward=-Z, right=+X,
up=+Y. HRTF LEFT=(-1,0,-1), CENTER=(0,0,-1), RIGHT=(1,0,-1) in arbitrary test
units. Rolloff=0; this is not a distance measurement or real bus coordinate.
HRTF processing API success does not prove a listener perceives the direction.

Stop disconnects the graph, stops the source and confirms context suspension.
Lost ended callbacks do not authorize overlapping output. Failed/unconfirmed stop
blocks new audio. Dispose closes the context independently of pending suspend.
The existing coordinator stops the graph before TTS/Live Hold and vice versa;
no interrupted sound is queued for automatic replay. Old epoch/request callbacks
are ignored. Lifecycle buttons simulate session end/logout/reset locally and do
not claim actual Firebase session integration. Existing actual session/polling
regressions must remain green separately.

## Reproduction and listening

Run scripts/build_local_spatial_verification.ps1 -OutputPath <new external dir>
with Flutter on PATH; it uses installed Malgun font and no CDN resources. Serve
only on127.0.0.1:5280. Only the generated test index enables the JS extension.

Use stereo headphones, keep volume comfortable, and explicitly click buttons:
1. STEREO CENTER, LEFT, RIGHT; let each finish (4s).
2. STEREO LEFT then RIGHT during playback; RIGHT then CENTER during playback.
3. Start any sound then STOP; repeat and check one source only.
4. Repeat1-3 with HRTF buttons, recording perceived direction separately.
5. During a tone press Live Hold; confirm tone stops before unchanged TTS starts.
6. During TTS start a tone and confirm no overlap; TTS is not spatialized.
7. Session end/logout, reset/new generation and page exit: confirm no residual
   sound. New session playback always needs a new explicit button press.

Automated graph/state tests and human listening are separate. Until user confirms,
AUDIBLE_DIRECTION_NOT_VERIFIED. Android, bone-conduction headphones, actual head
tracking and real environment geometry remain NOT_VERIFIED.

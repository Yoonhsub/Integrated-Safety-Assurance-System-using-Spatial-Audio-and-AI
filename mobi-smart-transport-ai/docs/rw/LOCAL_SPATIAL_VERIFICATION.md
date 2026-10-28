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

## Sequential directional Guidance verification

The same explicit debug page now offers LEFT/CENTER/RIGHT Cue → TTS and TTS-only.
This is SYNTHETIC_DIRECTIONAL_GUIDANCE, not a real model or Backend Safety Event.
The standard operational Guidance/SessionSafetyReceiver paths are unchanged.

Local immutable contract: guidanceId, sessionGeneration, authEpoch,
priority=observation, text, optional testDirection, provenance and
DirectionEvidence. A pinned lifecycle callback reuses the engine revision and
existing page request/epoch/generation guards. The callback includes the existing
priority gate, so claiming Live Hold invalidates a Cue before a following TTS.
Only provenance=SYNTHETIC_DIRECTIONAL_GUIDANCE plus explicitLocalFixture evidence
may play a directional Cue. Missing/unverified direction uses ordinary TTS only.
Every spoken integration message is prefixed as a synthetic verification message.

The existing engine registers an opaque one-shot command, runs one
SpeechPriorityCoordinator request, plays a600ms HRTF cue on the existing context,
awaits source completion AND confirmed output.stop, then prepares/plays existing
Web Speech. The utterance is not routed into Web Audio. Checks after every await
prevent a cancelled scope from continuing into TTS. Errors/cancellation propagate;
no fallback TTS after Cue/stop failure. No new coordinator or audio state machine.

Scoped duplicate key=[authEpoch,sessionGeneration,guidanceId]. Registration checks
before coordinator admission prevent duplicates from preempting current playback.
The existing project bounded128-ID dedup convention is reused; pending commands
are retired on completion/rejection and the registry clears on disposal. STOP or
Hold does not clear IDs or queue automatic replay. Session lifecycle buttons are
local verification only, not actual Firebase login/logout. Wrong generation/epoch
is refused before admission; future production direction binding needs verified
provenance and a real active-session adapter, not image bbox inference.

Human sequence: click LEFT Cue → TTS, then CENTER, then RIGHT and let each finish.
Click directionless TTS to check no Cue. To test Cue cancellation press STOP or
Live Hold immediately during its0.6s tone; for TTS cancellation press after speech
starts. End/logout/reset/page-exit tests must leave no old queued speech. Native
API/callback automation is separate from AUDIBLE_INTEGRATION confirmation.

## Future voice-buffer contract (not implemented)

Web Speech exposes no standard PCM extraction or AudioNode route. A future local
buffer provider must specify immutable source/provenance, guidance/session/epoch
ownership, PCM encoding or decoded AudioBuffer, finite sampleRate, channelCount,
frameCount and duration, channel layout, resource ownership/disposal, start/end/
error acknowledgement and cancellation. A cancelled or uncertain stop must keep
current quarantine and priority leases, never authorize another source early.

Direction requires a declared coordinate frame: head-relative listener axes
(+X right,+Y up,-Z forward), or world-relative direction with explicit calibrated
transform/timebase. Arbitrary test coordinates are not real distances. Real head
orientation must include timestamp, freshness and calibration, supplied by a
separate reviewed input. No yaw/pitch/roll correction, new TTS engine, external
voice API or PCM voice spatialization is introduced here.

The page-exit button invalidates the current scope and awaits existing STOP
before starting navigation. Widget disposal alone is too late during route
transition animations; no Cue-completion TTS may start in that window.

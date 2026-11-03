# Android local Stereo Cue + Korean TTS verification

Explicit debug entry only: `lib/local_android_audio_main.dart`, `MOBI_ANDROID_LOCAL_AUDIO=true`, applicationId `com.example.mobi_passenger_app.localaudio`. Gradle matches exact target/flag, forbids mixed/missing/false flags and disables profile/release variants. The generated debug overlay removes INTERNET, CAMERA and FirebaseInitProvider and selects a debug-source-only LocalAudioActivity. Normal Passenger, offlinevision and localbackend entry contracts are preserved. No Backend/Auth/camera/producer/Safety Event routes run here.

## Build and start

```powershell
flutter build apk --debug --no-pub -t lib/local_android_audio_main.dart --dart-define=MOBI_ANDROID_LOCAL_AUDIO=true
adb -s <approved-device> install -r <localaudio-debug.apk>
adb -s <approved-device> shell am start -n com.example.mobi_passenger_app.localaudio/com.example.mobi_passenger_app.LocalAudioActivity
```

Use the explicit screen buttons. No automatic playback. Do not install a normal Passenger APK as a substitute. Before each installation inspect the final APK package, permissions, Provider and launcher. Missing native channel/voice/focus/stop acknowledgement fails closed.

## Reused flow

The existing LocalSpatialVerificationPage, SpatialVerificationEngine, DirectionalGuidance, SpeechPriorityCoordinator, AudioShutdown/quarantine and Live Hold control are reused. A 3-second admission receipt applies to synthetic directional information; once admitted, normal Cue→TTS can cross freshness expiry while session/epoch/generation/cancellation remain checked. The existing30-second playback watchdog remains distinct. Native backgrounding invalidates the local session; returning foreground does not resume old audio.

The native adapter uses static AudioTrack PCM16 stereo at48kHz,440Hz,600ms with10ms fades and peak0.10. LEFT=(L1,R0), CENTER=(L0.707,R0.707), RIGHT=(L0,R1). Center means equal stereo channels, not proven frontal 3D perception. New one-shot tracks are released after completion/stop. Owner/run checks prevent old callbacks or dispose from stopping a new owner. Focus loss/duck cancels and never auto resumes. Callback timeout/cleanup failure poisons the native output and retains the existing quarantine; it is not confirmed cancellation. No HRTF, spatialized TTS, head tracking, distance or actual door direction is generated.

FlutterSpeechEngine still uses flutter_tts. Only this entry requires an explicitly offline (`network_required=0/false`) Korean voice; no voice/engine is downloaded. Missing Korean voice, unknown network requirement, failed voice/language selection or engine callbacks blocks the test. TTS callback telemetry is diagnostic, separate from real audible output. Native TTS itself is not routed through the PCM Cue graph.

## Bluetooth and Shokz

Use Android system Bluetooth pairing and select Shokz OpenRun Pro2 as media output. This app neither scans/pairs Bluetooth devices nor forces a route or changes volume. No Bluetooth-connect permission is needed for ordinary system-routed playback; device management is not implemented. Cue AudioTrack uses MEDIA/SONIFICATION attributes and transient audio focus. TTS uses its existing plugin path. Confirm both outputs reach the same device manually. The snapshot reports available output type/ID and last Cue routedDevice, not proof of a specific Shokz model or the TTS active route. No microphone/SCO/headset-call mode is enabled. Check system music volume, mono-audio/accessibility balance and safe listening level before comparing left/right. No volume is raised automatically.

Verify first plain Korean sentence, then LEFT/CENTER/RIGHT Cue→full sentence, TTS-only, STOP during Cue/TTS, Live Hold during Cue/TTS, logout/reset/session end, background/return, page exit and delayed callback/dispose. Observe available outputs vs actual active Cue route separately. Test Bluetooth disconnect/reconnect manually; no old utterance may automatically resume. All listening and actual route results remain DEVICE_AUDIO_NOT_VERIFIED until a real phone + Shokz is checked. Emulator callbacks are API/lifecycle evidence only.

Record load/voice availability, CUE_STARTED/COMPLETED/CANCELLED, TTS_STARTED/COMPLETED/STOP_CONFIRMED, current epoch/generation and activeTracks. `MobiLocalAudio` and `ANDROID_AUDIO_TTS` logs contain no speech payload or credentials. Data is local and not uploaded.

## Remaining platform acceptance

The local native TTS entry explicitly requests flutter_tts focus. Installed plugin4.2.5 requests transient-may-duck focus but does not expose the grant result or a meaningful focus-loss callback to Dart. Cue focus has its own checked grant/loss handling. External-app TTS focus loss and OEM delayed/duplicate terminal callbacks require device acceptance; plugin callbacks do not expose utterance IDs. Do not claim those as a verified device-level guarantee from fake tests.

For MODE_STATIC AudioTrack, STATE_NO_STATIC_DATA is a valid initial state. The implementation now verifies PCM write completion and STATE_INITIALIZED before play. Native callback timing still needs successful Runtime/device verification after the environment ANRs. Original failed attempts are preserved outside Git.

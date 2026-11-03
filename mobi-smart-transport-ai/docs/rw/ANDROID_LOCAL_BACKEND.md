# Android local Backend debug probe

This is a separate debug app (`com.example.mobi_passenger_app.localbackend`), not the networkless `.offlinevision` camera APK or a production login bypass.
The app never calls Firebase.initializeApp, opens a camera, uploads DetectionResult, creates Safety Events or enables audio. Fake identities are accepted only by the explicitly launched local host script. The ordinary app.main:app authentication is unchanged.

## Host

From the project root with the existing Backend Python environment:

```powershell
python -B scripts/run_android_local_backend.py --enable-local-test-auth --trace <external-evidence-directory>/backend-http.jsonl
```

The existing FastAPI app listens only on127.0.0.1:8000, refuses an occupied port, disables .env loading and external socket/DNS requests and uses in-memory storage. There is no selectable LAN host. Allowed APIs are health and existing guidance session/state/reset/event/polling only. AI Vision, Safety Events, FCM and all other routes are blocked. The fixture admin is used only for the existing BOARDED transition sequence to test closure; it does not grant Passenger the admin role in the normal app.

Self-contained host test, no Android assertion:

```powershell
python -B scripts/run_android_local_backend.py --enable-local-test-auth --self-test --trace <external-evidence-directory>/self-test.jsonl
```

## Android

```powershell
flutter build apk --debug --no-pub -t lib/local_android_backend_main.dart --dart-define=MOBI_ANDROID_LOCAL_BACKEND=true --dart-define=MOBI_API_BASE_URL=http://127.0.0.1:8000
adb devices -l
adb -s <approved-device> reverse tcp:8000 tcp:8000
# Install the localbackend APK only; do not replace the camera APK or ordinary Passenger.
adb -s <approved-device> install -r <localbackend-debug.apk>
```

Start the local Backend test app manually. Press the HTTP check button. It checks health, unauthenticated401, owner session create/state, the existing SessionSafetyReceiver baseline polling, foreign owner403 and reset→new receiver generation. Use the explicitly labelled fixture administrator end button to check BOARDED→polling403.
Logout and same-UID relogin invalidate the local request guard/receiver. Backgrounding logs out and does not automatically resume transmissions. Requests already received by the server cannot be undone.
Pair app `LOCAL_BACKEND_TRACE` attemptId with Backend response trace. The header is diagnostic only and can be forged by a host client; a header alone is not Android execution proof. Verify the package/process with ADB and correlate its device logs with server rows.

This debug app has INTERNET but its network security config allows cleartext only for127.0.0.1. Transport independently limits exact origin port8000 and API paths, refuses redirects and never logs tokens/headers. Fake tokens are intentionally invalid at ordinary Firebase-authenticated endpoints. Compile-time flag is guarded by Android/debug/explicit entry checks; Gradle rejects release/profile, normal-main use and simultaneous offline-camera mode. Ordinary app and camera offline policy remain intact.

Failure/timeout/401/403/500 abort the current check. The common authenticated client retains its bounded one refresh retry on current-generation401. No POST retry occurs for timeouts or500. Existing shared safety polling in-flight limits and2/4/8/16/30s backoff remain in use. Retry is an explicit user action after prior workflow completes; unknown mutations require checking host traces, never assuming they did not execute. dispose closes HTTP/receiver; no audio is enabled.

## Cleanup

Stop the development app, remove only this run's reverse mapping with `adb -s <approved-device> reverse --remove tcp:8000`, and stop the owned local host. Do not remove somebody else's existing reverse mapping. Do not change ADC, gcloud or cloud IAM. No connected device means DEVICE_RUNTIME_NOT_VERIFIED even when the APK and host self-test pass.

## Deferred

Camera uploads need a reviewed mobile provenance/envelope, producer role and server-owned session binding. Current v2 live intake expects webcam, not android_camera. No relabeling of source/model/class and no production authentication weakening are allowed.

Before sending any fixture authentication, the transport requires a successful health response with X-Mobi-Local-Probe=fake-auth-memory-v1. An ordinary Backend health200 without this test-host marker fails closed. This is an accidental-target guard, not cryptographic server attestation.

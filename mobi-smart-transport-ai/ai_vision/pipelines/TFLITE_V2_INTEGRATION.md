# Integration notes / 2026-10-14

Base: feat/ai-vision-custom-training 6519f80. Reference: feature/add-tflite-baseline 0d2b911.
User explicitly authorized cross-module integration in an isolated worktree. Source branches unchanged.
Only decoder/preprocessing logic was adapted; unsafe taxonomy text and spatial candidate policies were not imported.

## Runtime and profiles
Optional Python 3.13 Windows environment: tensorflow==2.20.0, opencv-python, numpy.
Existing YOLO dependencies/runtime remain independent. No implicit model downloads.
Four supplied TFLite artifacts loaded/invoked in actual TensorFlow Lite. All inputs are float32
[1,640,640,3], RGB 0..1 with aspect-preserving letterbox (padding 114).
COCO output [1,84,8400], project mapping only COCO index 5 -> bus.
Bus-door output [1,6,8400], indices 0 bus / 1 bus_door.
Parked-PM output [1,8,8400] (documented bus_stop, sidewalk_pole, tree_trunk, parked_pm).
Pole/tree output [1,6,8400] (documented pole, tree_trunk).
Obstacle artifacts are runtime-checked only, NOT service-mapped or field-validated.

Profiles pin complete SHA256, shape and dtype; a matching tensor shape alone is insufficient.
No quantized profile is supported. NMS is class-specific (IoU .45), confidence .5.
Odd letterbox padding uses the actual integer placement when undoing the transform.
Bad confidence fails conversion rather than being clamped. Input ID/time/source are preserved.
The adapter accepts the team's VisionResult payload only when its frame ID/time match the input;
legacy helpers that stamp inference-completion time must not be used for streaming.
Camera capture is still host-read time, unverified. Replay remains replay.

## Model availability and usage conditions
Model binaries stay external to this integration branch; use explicit absolute --model paths.
The team branch tracks binaries using Git LFS. Bus-door PT and TFLite SHA256 match release docs.
The model documents report public Roboflow/AI-Hub training and internal evaluation; those scores
were NOT reproduced here. Exact upstream dataset release/license and redistribution authorization
are not established by these local documents. Obtain provider/version/license records before
redistribution or deployment; this task does not assert legal clearance.

## Run
From the integration project, use the prepared local Auth/RTDB emulator + backend, and obtain an
admin-created replay camera/session Binding with the existing smoke/setup tools.
Run Python in an environment with the optional TensorFlow runtime:
python scripts/run_ai_vision_stream.py --provider tflite --tflite-profile bus-door --source video --video <existing-video> --model <verified-bus-door.tflite> --backend-url http://127.0.0.1:8011 --binding <server-binding.json> --email <local-producer-email> --max-frames 3 --report <new-report.json>
Password is requested with getpass, or supplied in process-only MOBI_VISION_PASSWORD.
The coco-bus profile uses its own verified artifact; --provider yolo preserves the existing path.

## Observation contract
DetectionResult and v2 ingestion schema are unchanged. Preview response observedClasses now also
permits bus_door. Server permits door projection only for the recognized TFLite model metadata.
This is an assertion by an authenticated, camera-bound producer, NOT remote model attestation.
The local provider checks the actual hash; a compromised producer remains a risk.
Flutter renders fixed observation text only. No TTS, distance, target identity or boarding permission.
stored=false, guidanceEligible=false, freshnessVerified=false retain their meanings.

## Remaining limits
Single-process Binding/session/cache, uncalibrated TTLs, no reliable sensor exposure timestamp.
The real E2E uses 3 repeated frames from a reviewed still, not a diverse field video.
Android camera/runtime/rotation/mirroring/device latency still require separate implementation.
Custom three-class 73-image training was not rerun; the imported model is a separate two-class model.

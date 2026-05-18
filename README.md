# Integrated Safety Assurance System using Spatial Audio and AI

## 1. Project Overview

This project is a smart public-transport safety assistance system for transportation-vulnerable users, especially visually impaired users and people who need additional support while moving through bus stops and boarding flows.

The system aims to connect a passenger mobile app, a driver mobile app, backend APIs, public transport data integration, BLE/sensor-based proximity recognition, voice guidance, and AI Vision-based risk detection into one assistive transport workflow.

The current stage is not a finished production service. It is a mock-first integrated MVP that is being advanced toward a more connected app-backend-centered V2 structure.

## 2. Core Problem

Transportation-vulnerable users can have difficulty understanding real-time bus arrival information, nearby safety risks, and driver-side boarding support status at the same time.

Most public transport information apps are still screen-centered, which limits accessibility for visually impaired users during fast, noisy, or crowded boarding situations. This project addresses the need for an assistive system that connects sensors, voice guidance, public data, passenger requests, and driver-side support into a single flow.

## 3. System Goals

- Provide bus arrival information and boarding support requests in the passenger app.
- Provide boarding support request review and status changes in the driver app.
- Connect mobile apps, public data, Firebase/mock storage, and safety events through the backend.
- Normalize bus arrival and low-floor bus information in the public data service.
- Provide stop/beacon proximity events through BLE and sensor modules.
- Prepare a structure where AI Vision obstacle or risk detections can become safety events.
- Support TTS/STT and accessibility-centered user flows.

## 4. Current Development Stage

The April-May implementation work produced mock-first MVP outputs by each team member's assigned area.

Current validation status:

- Architecture validation: PASS
- Backend pytest: 29 passed

The current V2 stage connects the separately implemented modules into an app-backend-centered integrated MVP. Live public data, real BLE devices, real AI inference, and complete spatial-audio directional guidance remain follow-up enhancement targets.

## 5. Repository Layout

```txt
mobi-smart-transport-ai/
  backend/api/                  # FastAPI backend and integration backbone
  apps/passenger_app/           # Passenger Flutter app
  apps/driver_app/              # Driver Flutter app
  services/public_data/         # Public data client and bus-arrival normalization
  packages/mobile_sensors/      # BLE, proximity, direction, and audio-cue package
  packages/shared_contracts/    # Shared API/event schema contracts
  ai_vision/                    # Dataset plan, model research, and AI Vision planning
  future_modules/               # Future spatial audio and head-tracking frames
  infrastructure/firebase/      # Firebase schema, rules, and examples
  docs/rw/                      # Working docs, V2 plan, contracts, setup notes
  docs/read/                    # Required reading, manifest, validation metadata
  scripts/                      # Architecture validation and helper scripts
```

## 6. Main Modules

- Backend / Integration Backbone: FastAPI APIs, ride request flow, bus info gateway, geofence checks, notifications, Firebase/mock integration, and future safety-event API planning.
- Passenger App: Passenger-side bus arrival display, boarding support request flow, accessibility UI, STT/TTS-oriented guidance, and V2 backend client integration.
- Driver App: Driver-side boarding support request list, request status updates, and FCM/backend integration targets.
- Public Data Service: Public transport API client, mock/live mode boundary, bus arrival normalization, low-floor bus handling, and backend gateway compatibility.
- Sensor / BLE / Audio Cue: BLE beacon signals, RSSI-based proximity estimation, direction sensor models, and audio cue mapping scaffolding.
- AI Vision: Dataset and model research assets, taxonomy planning, mock inference direction, and safety-event schema preparation.
- Documentation / Validation Scripts: V2 section plan, dependency map, API contracts, environment variables, package manifest, and architecture validation script.

## 7. V2 Development Plan

The V2 plan is documented in:

- [mobi-smart-transport-ai/docs/rw/V2_SECTION_PLAN.md](mobi-smart-transport-ai/docs/rw/V2_SECTION_PLAN.md)
- [mobi-smart-transport-ai/docs/rw/선행작업의존성 정리.md](<mobi-smart-transport-ai/docs/rw/선행작업의존성 정리.md>)
- [mobi-smart-transport-ai/docs/rw/공통 진행사항.md](<mobi-smart-transport-ai/docs/rw/공통 진행사항.md>)
- [mobi-smart-transport-ai/docs/rw/API_CONTRACTS.md](mobi-smart-transport-ai/docs/rw/API_CONTRACTS.md)
- [mobi-smart-transport-ai/docs/rw/ENVIRONMENT_VARIABLES.md](mobi-smart-transport-ai/docs/rw/ENVIRONMENT_VARIABLES.md)
- [mobi-smart-transport-ai/docs/rw/SETUP.md](mobi-smart-transport-ai/docs/rw/SETUP.md)

V2 is organized into 12 sections. Odd-numbered sections are implementation-centered, and even-numbered sections focus on validation, patching, and documentation. Team members should confirm their name, section sequence, ownership boundary, and dependencies in `mobi-smart-transport-ai/docs/rw/V2_SECTION_PLAN.md`.

## 8. Quick Start for Developers

From this top-level folder:

```bash
cd mobi-smart-transport-ai
python scripts/validate_architecture.py
```

Backend tests:

```bash
cd backend/api
PYTHONDONTWRITEBYTECODE=1 PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 python -m pytest tests -q -p no:cacheprovider
```

Windows PowerShell equivalent:

```powershell
cd backend/api
$env:PYTHONDONTWRITEBYTECODE="1"
$env:PYTEST_DISABLE_PLUGIN_AUTOLOAD="1"
python -m pytest tests -q -p no:cacheprovider
Remove-Item Env:PYTHONDONTWRITEBYTECODE
Remove-Item Env:PYTEST_DISABLE_PLUGIN_AUTOLOAD
```

## 9. Validation Status

- Architecture validation: PASS
- Backend pytest: 29 passed
- Flutter analyze/test: not guaranteed in this package unless Flutter SDK is available

## 10. Notes

- The project currently uses a mock-first MVP structure.
- Live mode requires environment variables and external credentials.
- Before real field use, the team must verify real-device BLE, live public data, Firebase/FCM, AI inference, and accessibility behavior in realistic environments.
- The file `인터뷰 준비.md` exists in the top-level wrapper folder as a separate note document and is not part of the `mobi-smart-transport-ai` package file manifest.

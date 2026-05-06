from __future__ import annotations

import json
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def repo_path(path: str) -> Path:
    """Resolve repo-relative paths robustly across NFC/NFD Unicode filenames."""
    direct = ROOT / path
    if direct.exists():
        return direct
    for form in ("NFD", "NFC"):
        normalized = ROOT / unicodedata.normalize(form, path)
        if normalized.exists():
            return normalized
    parts = [unicodedata.normalize("NFD", part) for part in Path(path).parts]
    component_normalized = ROOT.joinpath(*parts)
    if component_normalized.exists():
        return component_normalized
    return direct


def read_text(path: str) -> str:
    return repo_path(path).read_text(encoding="utf-8")


def assert_exists(path: str) -> None:
    if not repo_path(path).exists():
        raise AssertionError(f"Missing required path: {path}")


def _unicode_variants(value: str) -> tuple[str, ...]:
    return tuple(dict.fromkeys([value, unicodedata.normalize("NFD", value), unicodedata.normalize("NFC", value)]))


def assert_contains(path: str, needle: str) -> None:
    text = read_text(path)
    if not any(variant in text for variant in _unicode_variants(needle)):
        raise AssertionError(f"{path} must contain: {needle}")


def assert_not_contains(path: str, needle: str) -> None:
    text = read_text(path)
    for variant in _unicode_variants(needle):
        if variant in text:
            raise AssertionError(f"{path} must not contain obsolete text: {needle}")


def load_json(path: str) -> dict:
    with repo_path(path).open(encoding="utf-8") as f:
        return json.load(f)


def validate_required_paths() -> None:
    required = [
        "docs/rw/README.md",
        "docs/read/AGENT_REQUIRED_READING.md",
        "docs/read/프로젝트 4월분 개발에 관한 공통 프롬프트(AI 절대필독!).md",
        "docs/rw/API_CONTRACTS.md",
        "docs/rw/DATA_SCHEMA.md",
        "docs/rw/MODULE_OWNERSHIP.md",
        "docs/read/PULL_REQUEST_RULES.md",
        "docs/rw/선행작업의존성 정리.md",
        ".github/CODEOWNERS",
        ".github/pull_request_template.md",
        "docs/01_요구사항명세서.md",
        "docs/agent_required_reading/01_요구사항명세서.md",
        "backend/api/app/main.py",
        "backend/api/app/api/routes/bus_info_gateway.py",
        "backend/api/app/api/routes/driver_ride_requests.py",
        "backend/api/app/schemas/geofence.py",
        "backend/api/app/schemas/notification.py",
        "backend/api/app/schemas/ride_request.py",
        "packages/shared_contracts/api/bus_arrivals.response.schema.json",
        "packages/shared_contracts/api/driver_ride_requests.response.schema.json",
        "packages/shared_contracts/api/ride_request.create.request.schema.json",
        "packages/shared_contracts/api/ride_request.status_update.request.schema.json",
        "packages/shared_contracts/api/geofence_check.request.schema.json",
        "packages/shared_contracts/api/geofence_check.response.schema.json",
        "packages/shared_contracts/api/notification.request.schema.json",
        "packages/shared_contracts/api/notification.response.schema.json",
        "packages/shared_contracts/api/ride_request.schema.json",
        "infrastructure/firebase/database.rules.json",
        "infrastructure/firebase/realtime_database.schema.json",
        "packages/mobile_sensors/lib/src/beacon_signal.dart",
        "packages/mobile_sensors/lib/src/direction_sensor.dart",
        "apps/driver_app/pubspec.yaml",
        "packages/shared_contracts/events/event_types.json",
        "module_ownership.json",
    ]
    for path in required:
        assert_exists(path)


def validate_srs_single_source() -> None:
    assert_contains("docs/01_요구사항명세서.md", "# 모비 프로젝트 요구사항명세서(SRS)")
    assert_contains("docs/agent_required_reading/01_요구사항명세서.md", "docs/01_요구사항명세서.md")
    assert_not_contains("docs/agent_required_reading/01_요구사항명세서.md", "# AGENT REQUIRED READING")


def validate_api_contracts() -> None:
    assert_contains("docs/rw/API_CONTRACTS.md", "GET /bus-info/stops/{stopId}/arrivals")
    assert_contains("docs/01_요구사항명세서.md", "/bus-info/stops/{stopId}/arrivals")
    assert_not_contains("docs/01_요구사항명세서.md", "/bus/arrivals?stopId=")
    assert_not_contains("docs/01_요구사항명세서.md", "GET | /bus/locations?routeId=")
    assert_not_contains("docs/rw/API_CONTRACTS.md", "GET /bus-arrivals?stopId={stopId}")
    assert_not_contains("docs/rw/API_CONTRACTS.md", '"success": true')
    assert_not_contains("docs/rw/API_CONTRACTS.md", '"data": {}')
    assert_contains("docs/rw/API_CONTRACTS.md", "POST /notifications/send")
    assert_contains("docs/rw/API_CONTRACTS.md", "GET /drivers/{driverId}/ride-requests")
    assert_contains("backend/api/app/api/routes/bus_info_gateway.py", '"/stops/{stopId}/arrivals"')
    assert_contains("backend/api/app/api/routes/ride_requests.py", '"/{requestId}"')
    assert_contains("backend/api/app/api/routes/ride_requests.py", '"/{requestId}/status"')
    assert_contains("backend/api/app/api/routes/driver_ride_requests.py", '"/{driverId}/ride-requests"')
    assert_not_contains("backend/api/app/api/routes/bus_info_gateway.py", "{stop_id}")
    assert_not_contains("backend/api/app/api/routes/ride_requests.py", "{request_id}")
    assert_not_contains("backend/api/app/api/routes/driver_ride_requests.py", "{driver_id}")


def validate_shared_schemas() -> None:
    bus = load_json("packages/shared_contracts/api/bus_arrivals.response.schema.json")
    arrival_props = bus["properties"]["arrivals"]["items"]["properties"]
    if "source" in arrival_props or "stopName" in bus["properties"]:
        raise AssertionError("Bus arrivals app-facing schema must not contain source or stopName")

    geo_response = load_json("packages/shared_contracts/api/geofence_check.response.schema.json")
    if geo_response["properties"]["eventId"]["type"] != ["string", "null"]:
        raise AssertionError("geofence_check.response eventId must allow null")

    notification = load_json("packages/shared_contracts/api/notification.request.schema.json")
    enum_values = notification["properties"]["type"]["enum"]
    for value in ["SAFETY_ALERT", "RIDE_REQUEST", "SYSTEM"]:
        if value not in enum_values:
            raise AssertionError(f"Notification type enum missing {value}")
    if "oneOf" not in notification or "anyOf" in notification:
        raise AssertionError("NotificationRequest must use oneOf for exactly one target")
    for branch in notification["oneOf"]:
        props = branch.get("properties", {})
        if "targetUserId" in branch.get("required", []):
            if props.get("targetUserId", {}).get("type") != "string":
                raise AssertionError("NotificationRequest targetUserId branch must require a string targetUserId")
            if props.get("targetDriverId", {}).get("type") != "null":
                raise AssertionError("NotificationRequest targetUserId branch must require targetDriverId to be absent or null")
        if "targetDriverId" in branch.get("required", []):
            if props.get("targetDriverId", {}).get("type") != "string":
                raise AssertionError("NotificationRequest targetDriverId branch must require a string targetDriverId")
            if props.get("targetUserId", {}).get("type") != "null":
                raise AssertionError("NotificationRequest targetDriverId branch must require targetUserId to be absent or null")
        for key, spec in props.items():
            if key in {"targetUserId", "targetDriverId"} and spec.get("type") == "string":
                if spec.get("minLength") != 1 or spec.get("pattern") != "\\S":
                    raise AssertionError("NotificationRequest target fields must reject empty strings")

    create = load_json("packages/shared_contracts/api/ride_request.create.request.schema.json")
    status = load_json("packages/shared_contracts/api/ride_request.status_update.request.schema.json")
    for field in ["userId", "stopId", "routeId", "busNo"]:
        if field not in create.get("required", []):
            raise AssertionError(f"RideRequestCreate schema missing required field: {field}")
    expected_status = ["WAITING", "NOTIFIED", "ACCEPTED", "ARRIVED", "COMPLETED", "CANCELLED"]
    if status["properties"]["status"].get("enum") != expected_status:
        raise AssertionError("RideRequestStatusUpdate schema enum mismatch")


def validate_backend_schema_alignment() -> None:
    assert_contains("backend/api/app/main.py", "driver_ride_requests.router")
    assert_contains("backend/api/app/schemas/geofence.py", "userId: str")
    assert_contains("backend/api/app/schemas/geofence.py", "stopId: str")
    assert_contains("backend/api/app/schemas/geofence.py", "lat: float")
    assert_contains("backend/api/app/schemas/geofence.py", "lng: float")
    assert_contains("backend/api/app/schemas/geofence.py", "timestamp: datetime = None")
    assert_contains("backend/api/app/schemas/geofence.py", "reject_null_timestamp")
    assert_contains("backend/api/app/schemas/geofence.py", "timestamp는 생략할 수 있지만 null")
    assert_not_contains("backend/api/app/schemas/geofence.py", "latitude: float")
    assert_not_contains("backend/api/app/schemas/geofence.py", "longitude: float")
    assert_contains("backend/api/app/schemas/notification.py", "targetUserId: str | None = Field(default=None, min_length=1, pattern=NON_BLANK_PATTERN)")
    assert_contains("backend/api/app/schemas/notification.py", "targetDriverId: str | None = Field(default=None, min_length=1, pattern=NON_BLANK_PATTERN)")
    assert_contains("backend/api/app/schemas/notification.py", "type: NotificationType")
    assert_contains("backend/api/app/schemas/notification.py", "정확히 하나")
    assert_contains("backend/api/app/schemas/notification.py", "비어 있지 않은 문자열")
    assert_contains("backend/api/app/schemas/ride_request.py", "class DriverRideRequestsResponse")
    assert_contains("backend/api/app/schemas/ride_request.py", "pattern=NON_BLANK_PATTERN")


def validate_pr_template() -> None:
    template = read_text(".github/pull_request_template.md")
    for keyword in [
        "담당자",
        "관련 섹션",
        "브랜치명",
        "담당 범위 확인",
        "선행작업 의존성 확인",
        "공통 계약 영향",
        "충돌 이슈",
        "문서 최신화",
        "검증 결과",
        "병합 전 주의사항",
        "docs/rw/선행작업의존성 정리.md",
        "docs/rw/충돌 이슈.md",
        "최종 개발 보고서",
        "관련 없음",
    ]:
        if keyword not in template:
            raise AssertionError(f"PR template missing required keyword: {keyword}")
    if "충돌 가능성" in template or "## 9. 비고" in template:
        raise AssertionError("PR template must align with docs/read/PULL_REQUEST_RULES.md headings, not older weak headings")


def validate_ownership() -> None:
    ownership = load_json("module_ownership.json")
    if "owners" not in ownership:
        raise AssertionError("module_ownership.json missing owners")
    if ownership.get("ownership_source_of_truth") != "module_ownership.json":
        raise AssertionError("module_ownership.json must declare itself as source of truth")
    common_paths = ownership["owners"]["공통_아키텍처"]["owned_paths"]
    protected_paths = ownership.get("protected_paths", [])
    for path in [
        "docs/**",
        "docs/rw/API_CONTRACTS.md",
        "docs/rw/DATA_SCHEMA.md",
        "scripts/**",
        "docs/read/AGENT_REQUIRED_READING.md",
        "docs/read/프로젝트 4월분 개발에 관한 공통 프롬프트(AI 절대필독!).md",
        "docs/rw/충돌 이슈.md",
        "docs/rw/공통 진행사항.md",
        "docs/read/CONTRIBUTING.md",
        "docs/read/BRANCH_STRATEGY.md",
        "docs/read/COMMIT_CONVENTION.md",
        "docs/rw/ARCHITECTURE.md",
        "docs/rw/MODULE_OWNERSHIP.md",
        "docs/rw/SETUP.md",
        "docs/rw/ENVIRONMENT_VARIABLES.md",
        "docs/rw/PATCH_NOTES.md",
        "docs/read/심현석의 에이전트 필독사항.md",
        "docs/read/윤현섭의 에이전트 필독사항.md",
        "docs/read/안준환의 에이전트 필독사항.md",
        "docs/read/김도성의 에이전트 필독사항.md",
        "docs/rw/선행작업의존성 정리.md",
        "docs/read/architecture_validation_result.txt",
    ]:
        if path not in common_paths:
            raise AssertionError(f"공통_아키텍처 owned_paths missing {path}")
        if path not in protected_paths:
            raise AssertionError(f"protected_paths missing common doc: {path}")
    def covered_by(patterns: list[str], path: str) -> bool:
        for pattern in patterns:
            if pattern == path:
                return True
            if pattern.endswith("/**") and path.startswith(pattern[:-3]):
                return True
            if path.endswith("/**") and pattern.startswith(path[:-3]):
                return True
        return False

    missing_from_owned = [path for path in protected_paths if not covered_by(common_paths, path)]
    if missing_from_owned:
        raise AssertionError(f"protected_paths must be subset of 공통_아키텍처 owned_paths: {missing_from_owned}")
    unprotected_common = [path for path in common_paths if not covered_by(protected_paths, path)]
    if unprotected_common:
        raise AssertionError(f"공통_아키텍처 owned_paths must be protected: {unprotected_common}")


def _is_packaged_source_file(path: Path) -> bool:
    rel = path.relative_to(ROOT).as_posix()
    if not path.is_file():
        return False
    if rel.startswith(".git/"):
        return False
    forbidden_parts = {
        "__pycache__",
        ".pytest_cache",
        ".dart_tool",
        "build",
        "node_modules",
        ".firebase",
        ".gcloud",
        "logs",
    }
    if any(part in forbidden_parts for part in path.relative_to(ROOT).parts):
        return False
    forbidden_names = {".DS_Store", ".env"}
    if path.name in forbidden_names:
        return False
    forbidden_suffixes = {".pyc", ".log", ".zip", ".tar", ".tgz", ".7z", ".rar"}
    if path.suffix in forbidden_suffixes:
        return False
    if rel.endswith(".tar.gz"):
        return False
    return True


def validate_manifest() -> None:
    final_file_list = ROOT / "docs/read/FINAL_FILE_LIST.txt"
    if not final_file_list.exists():
        raise AssertionError("Missing docs/read/FINAL_FILE_LIST.txt")
    listed = {line.strip() for line in final_file_list.read_text(encoding="utf-8").splitlines() if line.strip()}
    actual = {
        path.relative_to(ROOT).as_posix()
        for path in ROOT.rglob("*")
        if _is_packaged_source_file(path)
    }
    missing = sorted(listed - actual)
    unlisted = sorted(actual - listed)
    if missing:
        raise AssertionError(f"docs/read/FINAL_FILE_LIST.txt contains missing files: {missing[:20]}")
    if unlisted:
        raise AssertionError(f"docs/read/FINAL_FILE_LIST.txt omits packaged files: {unlisted[:20]}")


def validate_no_generated_ignored_files() -> None:
    forbidden = []
    forbidden_dirs = {
        "__pycache__",
        ".pytest_cache",
        ".dart_tool",
        "build",
        "node_modules",
        ".firebase",
        ".gcloud",
        "logs",
    }
    forbidden_file_names = {".DS_Store", ".env"}
    forbidden_suffixes = {".pyc", ".log", ".zip", ".tar", ".tgz", ".7z", ".rar"}
    for path in ROOT.rglob("*"):
        rel = path.relative_to(ROOT).as_posix()
        if rel.startswith(".git/"):
            continue
        parts = path.relative_to(ROOT).parts
        if path.is_dir() and path.name in forbidden_dirs:
            forbidden.append(rel + "/")
        elif path.is_file():
            if any(part in forbidden_dirs for part in parts):
                forbidden.append(rel)
            elif path.name in forbidden_file_names:
                forbidden.append(rel)
            elif path.suffix in forbidden_suffixes or rel.endswith(".tar.gz"):
                forbidden.append(rel)
    if forbidden:
        raise AssertionError(f"Generated/ignored files must not be packaged: {forbidden[:20]}")

    final_file_list = ROOT / "docs/read/FINAL_FILE_LIST.txt"
    if final_file_list.exists():
        text = final_file_list.read_text(encoding="utf-8")
        lines = {line.strip() for line in text.splitlines() if line.strip()}
        exact_forbidden = {".env", ".DS_Store"}
        for obsolete in exact_forbidden:
            if obsolete in lines:
                raise AssertionError(f"docs/read/FINAL_FILE_LIST.txt must not contain generated/ignored entry: {obsolete}")
        for obsolete in [
            "__pycache__",
            ".pyc",
            ".pytest_cache",
            "node_modules",
            ".dart_tool",
            ".firebase",
            ".gcloud",
            ".zip",
            ".tar",
            ".7z",
            ".rar",
            "logs/",
            ".log",
        ]:
            if obsolete in text:
                raise AssertionError(f"docs/read/FINAL_FILE_LIST.txt must not contain generated/ignored entry: {obsolete}")


def validate_codeowners_alignment() -> None:
    codeowners = read_text(".github/CODEOWNERS")
    ownership = load_json("module_ownership.json")
    owner_handles = {
        name: f"@{spec['github']}"
        for name, spec in ownership["owners"].items()
        if name != "공통_아키텍처"
    }
    expected_single_owner_lines = {
        "/apps/passenger_app/": owner_handles["윤현섭"],
        "/apps/driver_app/": owner_handles["윤현섭"],
        "/packages/mobile_sensors/": owner_handles["안준환"],
        "/backend/api/": owner_handles["심현석"],
        "/infrastructure/firebase/": owner_handles["심현석"],
        "/services/public_data/": owner_handles["김도성"],
        "/ai_vision/": owner_handles["김도성"],
    }
    for path, handle in expected_single_owner_lines.items():
        line = f"{path} {handle}"
        if line not in codeowners:
            raise AssertionError(f"CODEOWNERS missing or misaligned owner line: {line}")

    all_reviewers = "@Yoonhsub @ajh1206 @loremipsum0116 @doseong13"
    for path in [
        "/packages/shared_contracts/",
        "/.github/",
        "/future_modules/",
        "/scripts/",
        "/docs/",
        "/docs/rw/README.md",
        "/docs/rw/API_CONTRACTS.md",
        "/docs/rw/DATA_SCHEMA.md",
        "/docs/rw/MODULE_OWNERSHIP.md",
        "/docs/read/PACKAGE_MANIFEST.txt",
        "/docs/read/FINAL_FILE_LIST.txt",
        "/docs/rw/PATCH_NOTES.md",
        "/docs/read/architecture_validation_result.txt",
        r"/docs/rw/선행작업의존성\ 정리.md",
    ]:
        line = f"{path} {all_reviewers}"
        if line not in codeowners:
            raise AssertionError(f"CODEOWNERS common/protected path must require all reviewers: {line}")


def validate_agent_reading_prompt() -> None:
    prompt_name = "docs/read/프로젝트 4월분 개발에 관한 공통 프롬프트(AI 절대필독!).md"
    assert_contains("docs/read/AGENT_REQUIRED_READING.md", f"`{prompt_name}`")
    assert_contains("docs/rw/README.md", f"`{prompt_name}`")


def validate_geofence_schema_alignment() -> None:
    data_schema = read_text("docs/rw/DATA_SCHEMA.md")
    rtdb_schema = read_text("infrastructure/firebase/realtime_database.schema.json")
    for needle in [
        '"safeZone": [',
        '"warningZones": [',
        '"dangerZones": [',
        '"polygon": [',
        '"name": "string"',
    ]:
        if needle not in data_schema and needle not in rtdb_schema:
            raise AssertionError(f"geofence schema alignment missing {needle}")
    assert_not_contains("docs/rw/DATA_SCHEMA.md", '"safeZone": {')
    assert_not_contains("docs/rw/DATA_SCHEMA.md", '"coordinates": [')
    assert_not_contains("docs/rw/DATA_SCHEMA.md", '"zoneId"')


def validate_mobile_sensor_contracts() -> None:
    beacon = read_text("packages/mobile_sensors/lib/src/beacon_signal.dart")
    direction = read_text("packages/mobile_sensors/lib/src/direction_sensor.dart")
    driver_pubspec = read_text("apps/driver_app/pubspec.yaml")
    assert_contains("packages/mobile_sensors/lib/src/beacon_signal.dart", "final BeaconSignalLevel signalLevel;")
    assert_contains("packages/mobile_sensors/lib/src/beacon_signal.dart", "VERY_CLOSE")
    assert_contains("packages/mobile_sensors/lib/src/direction_sensor.dart", "enum DirectionAccuracy")
    assert_contains("packages/mobile_sensors/lib/src/direction_sensor.dart", "final DirectionAccuracy accuracy;")
    assert_contains("packages/mobile_sensors/lib/src/direction_sensor.dart", "final DateTime updatedAt;")
    for obsolete in ["mobi_mobile_sensors", "flutter_tts", "speech_to_text"]:
        if obsolete in driver_pubspec:
            raise AssertionError(f"driver_app pubspec must not depend on passenger-only package: {obsolete}")


def validate_enum_consistency() -> None:
    events = load_json("packages/shared_contracts/events/event_types.json")
    expected = {
        "congestion_level": ["LOW", "NORMAL", "HIGH", "UNKNOWN"],
        "ride_request_status": ["WAITING", "NOTIFIED", "ACCEPTED", "ARRIVED", "COMPLETED", "CANCELLED"],
        "beacon_signal_level": ["VERY_CLOSE", "CLOSE", "MEDIUM", "FAR", "LOST"],
        "direction_accuracy": ["HIGH", "MEDIUM", "LOW", "UNKNOWN"],
    }
    for key, values in expected.items():
        if events.get(key) != values:
            raise AssertionError(f"event_types.json {key} mismatch: {events.get(key)}")
    bus_backend = read_text("backend/api/app/schemas/bus_info.py")
    bus_public = read_text("services/public_data/public_data_client/schemas.py")
    for value in expected["congestion_level"]:
        assert_contains("backend/api/app/schemas/bus_info.py", f'{value} = "{value}"')
        assert_contains("services/public_data/public_data_client/schemas.py", f'{value} = "{value}"')
    ride_backend = read_text("backend/api/app/schemas/ride_request.py")
    for value in expected["ride_request_status"]:
        assert_contains("backend/api/app/schemas/ride_request.py", f'{value} = "{value}"')


def validate_meta_document_consistency() -> None:
    for path in ["docs/rw/충돌 이슈.md", "docs/read/COMMIT_CONVENTION.md", "docs/read/PULL_REQUEST_RULES.md", "docs/rw/선행작업의존성 정리.md", "docs/rw/공통 진행사항.md"]:
        assert_not_contains(path, "CONFLICT-000")
    assert_contains("docs/rw/충돌 이슈.md", "CONFLICT-YYYYMMDD-HHMM-담당자명-번호")
    assert_contains("docs/read/COMMIT_CONVENTION.md", "CONFLICT-YYYYMMDD-HHMM-담당자명-번호")
    assert_contains("docs/read/CONTRIBUTING.md", "docs/read/프로젝트 4월분 개발에 관한 공통 프롬프트(AI 절대필독!).md`의 §2.1")
    assert_contains("docs/rw/공통 진행사항.md", "## 공통 진행사항")



def validate_runtime_constraints() -> None:
    assert_contains("backend/api/app/schemas/bus_info.py", "arrivalMinutes: int = Field(ge=0)")
    assert_contains("backend/api/app/schemas/bus_info.py", "remainingStops: int | None = Field(default=None, ge=0)")
    assert_contains("services/public_data/public_data_client/schemas.py", "arrivalMinutes: int = Field(ge=0)")
    assert_contains("services/public_data/public_data_client/schemas.py", "remainingStops: int | None = Field(default=None, ge=0)")



def _assert_strict_current_location_rule(rule: str, label: str) -> None:
    required_fragments = [
        "newData.hasChildren(['lat', 'lng', 'updatedAt'])",
        "newData.childrenCount() === 3",
        "newData.child('lat').isNumber()",
        "newData.child('lat').val() >= -90",
        "newData.child('lat').val() <= 90",
        "newData.child('lng').isNumber()",
        "newData.child('lng').val() >= -180",
        "newData.child('lng').val() <= 180",
        "newData.child('updatedAt').isString()",
    ]
    for fragment in required_fragments:
        if fragment not in rule:
            raise AssertionError(f"{label} currentLocation rule missing strict validation fragment: {fragment}")

def validate_fcm_and_firebase_policy() -> None:
    assert_contains("docs/rw/DATA_SCHEMA.md", "공식 저장 위치는 `/fcmTokens/{ownerType}/{ownerId}`")
    assert_not_contains("docs/rw/DATA_SCHEMA.md", '"fcmToken": "token_example"')
    assert_not_contains("docs/rw/DATA_SCHEMA.md", '"fcmToken": "driver_token_example"')
    rtdb = load_json("infrastructure/firebase/realtime_database.schema.json")
    if "fcmToken" in rtdb["users"]["$userId"] or "fcmToken" in rtdb["drivers"]["$driverId"]:
        raise AssertionError("FCM token must not be duplicated under users/drivers")
    if rtdb["users"]["$userId"].get("userType") != "visually_impaired | elderly | general | unknown":
        raise AssertionError("userType enum mismatch")
    rules_json = load_json("infrastructure/firebase/database.rules.json")
    user_location_rule = rules_json["rules"]["users"]["$uid"]["currentLocation"].get(".validate", "")
    driver_location_rule = rules_json["rules"]["drivers"]["$driverId"]["currentLocation"].get(".validate", "")
    _assert_strict_current_location_rule(user_location_rule, "users/{uid}")
    _assert_strict_current_location_rule(driver_location_rule, "drivers/{driverId}")
    ride_rules = rules_json["rules"].get("rideRequests", {})
    if ride_rules.get(".write") is not False:
        raise AssertionError("rideRequests RTDB writes must be disabled; use FastAPI/Admin SDK")
    assert_contains("backend/api/app/services/fcm_service.py", "/fcmTokens/users/{userId}")
    assert_contains("backend/api/app/services/fcm_service.py", "/fcmTokens/drivers/{driverId}")


def validate_setup_and_env() -> None:
    assert_contains(".env.example", "PUBLIC_DATA_BASE_URL=https://apis.data.go.kr")
    assert_contains("docs/rw/ENVIRONMENT_VARIABLES.md", "PUBLIC_DATA_BASE_URL=https://apis.data.go.kr")
    assert_contains("services/public_data/public_data_client/data_go_kr_client.py", 'os.getenv("PUBLIC_DATA_BASE_URL") or "https://apis.data.go.kr"')
    assert_contains("docs/rw/SETUP.md", "uvicorn app.main:app --reload")
    assert_not_contains("docs/rw/SETUP.md", "uvicorn main:app --reload")
    assert_contains("docs/rw/README.md", "`docs/01_요구사항명세서.md`")


def validate_dependency_wording() -> None:
    for path in [
        "docs/read/심현석의 에이전트 필독사항.md",
        "docs/read/윤현섭의 에이전트 필독사항.md",
        "docs/read/안준환의 에이전트 필독사항.md",
        "docs/read/김도성의 에이전트 필독사항.md",
    ]:
        assert_contains(path, "선행 산출물이 필요한 하위 작업만 보류")
        assert_not_contains(path, "선행 섹션이 (미구현)이면 해당 섹션 작업을 중단한다")
    assert_contains("docs/rw/선행작업의존성 정리.md", "선행 산출물이 필요한 하위 작업만 보류")


def validate_priority_and_scope_docs() -> None:
    for path in [
        "docs/read/프로젝트 4월분 개발에 관한 공통 프롬프트(AI 절대필독!).md",
        "docs/read/CONTRIBUTING.md",
    ]:
        assert_contains(path, "계약 영역별 우선순위 분리")
        assert_contains(path, "역할/범위/섹션 진행 기준")
        assert_contains(path, "API 필드명/응답 구조/enum 기준")
        assert_contains(path, "Firebase RTDB 경로/필드 기준")
        assert_contains(path, "packages/shared_contracts/api/*.schema.json")
        assert_contains(path, "infrastructure/firebase/realtime_database.schema.json")


def validate_docs02_current_structure() -> None:
    for path in [
        "docs/02_4월_개인별_구현범위_수정안.md",
        "docs/agent_required_reading/02_4월_개인별_구현범위_수정안.md",
    ]:
        assert_contains(path, "backend/api/")
        assert_contains(path, "main.py")
        assert_contains(path, "routes/")
        assert_contains(path, "bus_info_gateway.py")
        assert_contains(path, "firebase_client.py")
        assert_contains(path, "schemas/")
        assert_not_contains(path, "backend/main.py")
        assert_not_contains(path, "geofence_routes.py")
        assert_not_contains(path, "notification_routes.py")
        assert_not_contains(path, "ride_request_routes.py")
        assert_not_contains(path, "bus_info_routes.py")
        assert_not_contains(path, "firebase_service.py")
        assert_not_contains(path, '"congestion": "normal"')
        assert_not_contains(path, "2026-04-xx")
        assert_not_contains(path, "signalStrengthLevel")
        assert_not_contains(path, "estimatedDistance\n")
        assert_not_contains(path, "detectedAt")
        assert_contains(path, '"congestion": "NORMAL"')
        assert_contains(path, "estimatedDistanceMeters")
        assert_contains(path, "signalLevel")
        assert_contains(path, "lastDetectedAt")
        assert_contains(path, "headingDegrees")
        assert_contains(path, "updatedAt")


def validate_srs_official_paths_and_examples() -> None:
    assert_contains("docs/01_요구사항명세서.md", "4월 MVP의 공식 Firebase RTDB 최상위 경로")
    assert_contains("docs/01_요구사항명세서.md", "`alerts/{alertId}`는 4월 공식 RTDB 경로가 아니다")
    assert_contains("docs/01_요구사항명세서.md", "`beaconSignals/{deviceId}`는 4월 공식 RTDB 경로가 아니다")
    assert_not_contains("docs/01_요구사항명세서.md", "| alerts/{alertId} |")
    assert_not_contains("docs/01_요구사항명세서.md", "| beaconSignals/{deviceId} |")
    assert_not_contains("docs/01_요구사항명세서.md", "distanceLevel")
    assert_not_contains("docs/01_요구사항명세서.md", "detectedAt")
    assert_not_contains("docs/01_요구사항명세서.md", "2026-04-xx")
    assert_contains("docs/01_요구사항명세서.md", "headingDegrees, accuracy, updatedAt")
    assert_contains("docs/01_요구사항명세서.md", "beaconId, rssi, estimatedDistanceMeters, signalLevel, lastDetectedAt")


def validate_json_schema_strictness() -> None:
    geofence = load_json("packages/shared_contracts/api/geofence_check.request.schema.json")
    if geofence["properties"]["timestamp"].get("type") != "string":
        raise AssertionError("Geofence timestamp schema must allow omission, not explicit null")
    ride_create = load_json("packages/shared_contracts/api/ride_request.create.request.schema.json")
    for field in ["userId", "stopId", "routeId", "busNo", "targetDriverId"]:
        spec = ride_create["properties"][field]
        if spec.get("minLength") != 1 or spec.get("pattern") != "\\S":
            raise AssertionError(f"RideRequestCreate field must reject blank strings: {field}")


def validate_setup_and_patch_notes_current() -> None:
    assert_contains("docs/rw/SETUP.md", "Architecture validation: PASS")
    assert_not_contains("docs/rw/SETUP.md", "[OK] MOBI architecture skeleton")
    assert_contains("docs/rw/PATCH_NOTES.md", "v3에서 superseded")
    assert_contains("docs/rw/PATCH_NOTES.md", "## v4 consistency patch")


def validate_data_schema_examples_align_rtdb() -> None:
    data = read_text("docs/rw/DATA_SCHEMA.md")
    assert_contains("docs/rw/DATA_SCHEMA.md", '"busNo": "502"')
    assert_contains("docs/rw/DATA_SCHEMA.md", '"routeId": "route502"')
    assert_contains("docs/rw/DATA_SCHEMA.md", "drivers`에는 운행 관련 필드만 둔다")
    assert_contains("docs/rw/DATA_SCHEMA.md", "공식 RTDB schema에는 `createdAt`, `updatedAt`을 두지 않는다")
    driver_section = data.split("## 4. drivers", 1)[1].split("## 5. busStops", 1)[0]
    for obsolete in ['"role": "driver"', '"displayName": "기사"', '"createdAt":']:
        if obsolete in driver_section:
            raise AssertionError(f"DATA_SCHEMA drivers example must not contain obsolete field: {obsolete}")
    bus_stop_section = data.split("## 5. busStops", 1)[1].split("## 6. geofences", 1)[0]
    for obsolete in ['"createdAt":', '"updatedAt":']:
        if obsolete in bus_stop_section:
            raise AssertionError(f"DATA_SCHEMA busStops example must not contain obsolete field: {obsolete}")


def validate_stale_path_examples_removed() -> None:
    assert_not_contains("docs/read/COMMIT_CONVENTION.md", "backend/api/main.py")
    assert_not_contains("docs/read/COMMIT_CONVENTION.md", "backend/api/app/routes/health.py")
    assert_contains("docs/read/COMMIT_CONVENTION.md", "backend/api/app/main.py")
    assert_contains("docs/read/COMMIT_CONVENTION.md", "backend/api/app/api/routes/ride_requests.py")
    assert_not_contains("docs/read/PULL_REQUEST_RULES.md", "services/public_data/mock/bus_arrivals.json")
    assert_contains("docs/read/PULL_REQUEST_RULES.md", "services/public_data/examples/mock_bus_arrivals.json")


def validate_flutter_structure_docs() -> None:
    for path in [
        "docs/02_4월_개인별_구현범위_수정안.md",
        "docs/agent_required_reading/02_4월_개인별_구현범위_수정안.md",
    ]:
        assert_contains(path, "apps/passenger_app/lib/")
        assert_contains(path, "apps/driver_app/lib/")
        assert_contains(path, "src/")
        assert_contains(path, "backend_api_client.dart")
        assert_not_contains(path, "lib/\n  main.dart\n  app.dart")
        assert_not_contains(path, "backend_api_service.dart")


def validate_driver_notification_todo() -> None:
    assert_contains("apps/driver_app/lib/src/services/backend_api_client.dart", "FCM 수신 핸들러 연동")
    assert_not_contains("apps/driver_app/lib/src/services/backend_api_client.dart", "/notifications/send 수신 연동")



def validate_v6_doc_contract_cleanup() -> None:
    # Health examples must include service field everywhere critical.
    assert_contains("docs/01_요구사항명세서.md", "{status: ok, service: mobi-backend-api}")
    assert_contains("docs/01_요구사항명세서.md", '{"status":"ok","service":"mobi-backend-api"}')
    for path in [
        "docs/02_4월_개인별_구현범위_수정안.md",
        "docs/agent_required_reading/02_4월_개인별_구현범위_수정안.md",
    ]:
        assert_contains(path, '"service": "mobi-backend-api"')
        assert_contains(path, '"stopId": "stop001"')
        assert_contains(path, '"arrivals": [')
        assert_contains(path, '"lowFloor": true')
        assert_contains(path, '"updatedAt": "2026-04-18T14:32:00+09:00"')
        assert_not_contains(path, "\"remainingStops\": 2\n  }\n]\n```")

    # Old conflict placeholder must not survive in any operational markdown.
    for path in [
        "docs/read/안준환의 에이전트 필독사항.md",
        "docs/rw/충돌 이슈.md",
        "docs/read/COMMIT_CONVENTION.md",
        "docs/read/PULL_REQUEST_RULES.md",
    ]:
        assert_not_contains(path, "CONFLICT-XXXX")
    assert_contains("docs/read/안준환의 에이전트 필독사항.md", "CONFLICT-YYYYMMDD-HHMM-담당자명-번호")

    # Reading order and contract-specific priority wording must be explicit.
    assert_contains("docs/read/AGENT_REQUIRED_READING.md", "읽기 권장 순서")
    assert_contains("docs/read/AGENT_REQUIRED_READING.md", "충돌 해결 우선순위가 아니라")
    assert_not_contains("docs/read/AGENT_REQUIRED_READING.md", "| 우선순위 | 파일 | 목적 |")
    assert_contains("docs/read/프로젝트 4월분 개발에 관한 공통 프롬프트(AI 절대필독!).md", "일반 업무/역할 범위 우선순위")
    assert_contains("docs/read/프로젝트 4월분 개발에 관한 공통 프롬프트(AI 절대필독!).md", "계약 영역별 우선순위가 이 일반 우선순위보다 우선")

    # DATA_SCHEMA role description must match RTDB enum.
    assert_contains("docs/rw/DATA_SCHEMA.md", "passenger, driver, admin")


def validate_openapi_contract_notice() -> None:
    assert_contains("docs/rw/API_CONTRACTS.md", "OpenAPI 보조 기준")
    assert_contains("docs/rw/API_CONTRACTS.md", "shared JSON Schema를 따른다")
    assert_contains("backend/api/app/schemas/notification.py", "model_config = ConfigDict")
    assert_contains("backend/api/app/schemas/notification.py", "json_schema_extra")
    assert_contains("backend/api/app/schemas/ride_request.py", "createdAt: datetime")
    assert_contains("backend/api/app/schemas/bus_info.py", "updatedAt: datetime")
    assert_contains("services/public_data/public_data_client/schemas.py", "updatedAt: datetime")


def validate_v7_remaining_consistency() -> None:
    # No stale mobile sensor field aliases should remain in operational markdown.
    for path in [
        "docs/read/심현석의 에이전트 필독사항.md",
        "docs/read/윤현섭의 에이전트 필독사항.md",
        "docs/read/안준환의 에이전트 필독사항.md",
        "docs/read/김도성의 에이전트 필독사항.md",
        "docs/01_요구사항명세서.md",
        "docs/02_4월_개인별_구현범위_수정안.md",
        "docs/agent_required_reading/02_4월_개인별_구현범위_수정안.md",
    ]:
        assert_not_contains(path, "signalStrengthLevel")
        assert_not_contains(path, "distanceLevel")
        assert_not_contains(path, "detectedAt")

    # lowFloor is an app-facing boolean contract. Raw unknown values must be normalized before API output.
    assert_contains("docs/01_요구사항명세서.md", "lowFloor: true/false")
    assert_contains("docs/01_요구사항명세서.md", "앱-facing API의 `lowFloor`는 boolean으로 고정")
    assert_not_contains("docs/01_요구사항명세서.md", "lowFloor: true/false/unknown")
    assert_not_contains("docs/01_요구사항명세서.md", "unknown 또는 false 정책")

    # Congestion enum wording must use the official uppercase UNKNOWN when referring to the contract.
    for path in [
        "docs/read/윤현섭의 에이전트 필독사항.md",
        "docs/02_4월_개인별_구현범위_수정안.md",
        "docs/agent_required_reading/02_4월_개인별_구현범위_수정안.md",
    ]:
        assert_not_contains(path, "congestion 또는 unknown")
        assert_not_contains(path, "혼잡도 정보가 없을 경우 unknown 처리")
        assert_contains(path, "UNKNOWN")

    # RTDB schema labels should match the integer API/Pydantic contract for bus arrivals.
    rtdb = load_json("infrastructure/firebase/realtime_database.schema.json")
    bus = rtdb["busArrivals"]["$stopId"]["$routeId"]
    if bus.get("arrivalMinutes") != "integer":
        raise AssertionError("RTDB busArrivals arrivalMinutes must be labelled integer")
    if bus.get("remainingStops") != "integer | null":
        raise AssertionError("RTDB busArrivals remainingStops must be labelled integer | null")

    # Test documentation should use the reproducible pytest command used for this package.
    assert_contains("docs/read/architecture_validation_result.txt", "PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 python -m pytest -q -p no:cacheprovider")
    assert_contains("docs/rw/SETUP.md", "PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 python -m pytest -q -p no:cacheprovider")
    assert_contains("docs/rw/PATCH_NOTES.md", "## v7 consistency patch")


def validate_v8_service_datetime_and_env() -> None:
    for path in [
        "backend/api/app/services/ride_request_service.py",
        "backend/api/app/services/bus_info_gateway_service.py",
        "services/public_data/public_data_client/bus_arrivals_service.py",
    ]:
        assert_not_contains(path, ".isoformat()")
        assert_contains(path, "datetime.now(timezone.utc)")
    assert_contains("services/public_data/public_data_client/data_go_kr_client.py", "from dotenv import load_dotenv")
    assert_contains("services/public_data/public_data_client/data_go_kr_client.py", "load_dotenv()")


def validate_v8_policy_docs() -> None:
    assert_contains("module_ownership.json", "docs/rw/선행작업의존성 정리.md")
    assert_contains("module_ownership.json", "docs/read/architecture_validation_result.txt")
    assert_contains(".github/CODEOWNERS", "/docs/rw/선행작업의존성\\ 정리.md")
    assert_contains(".github/CODEOWNERS", "/docs/read/architecture_validation_result.txt")
    assert_contains("apps/passenger_app/README.md", "mobi_mobile_sensors")
    assert_contains("apps/passenger_app/README.md", "placeholder/mock 기반 UI shell")
    assert_contains("docs/rw/선행작업의존성 정리.md", "mobi_mobile_sensors")
    assert_contains("docs/rw/선행작업의존성 정리.md", "mock/placeholder 소비 구조")
    assert_contains("docs/rw/DATA_SCHEMA.md", "FCM 토큰 등록 책임은 Flutter 클라이언트")
    assert_contains("docs/rw/DATA_SCHEMA.md", "/fcmTokens/users/{auth.uid}")
    assert_contains("docs/rw/DATA_SCHEMA.md", "/fcmTokens/drivers/{auth.uid}")
    assert_contains("docs/rw/DATA_SCHEMA.md", "driverId`는 Firebase Auth UID와 동일")
    assert_contains("docs/rw/DATA_SCHEMA.md", "auth.uid === driverId")


def validate_v8_srs_examples_and_reading_order() -> None:
    assert_contains("docs/01_요구사항명세서.md", '"routeId": "route502"')
    assert_not_contains("docs/01_요구사항명세서.md", '"routeId": "502"')
    assert_contains("docs/01_요구사항명세서.md", '"eventId": "event001"')
    assert_contains("docs/01_요구사항명세서.md", "eventId`는 이벤트가 생성되지 않은 경우 `null`")
    for path in [
        "docs/read/AGENT_REQUIRED_READING.md",
        "docs/read/프로젝트 4월분 개발에 관한 공통 프롬프트(AI 절대필독!).md",
    ]:
        assert_contains(path, "프로젝트 4월분 개발에 관한 공통 프롬프트")
        assert_contains(path, "docs/rw/선행작업의존성 정리.md")
        assert_contains(path, "docx")
        assert_contains(path, "제출/공유용 참고 문서")


def validate_v9_minor_consistency_cleanup() -> None:
    # Shared contract name should be BusArrivalsResponse; NormalizedBusArrivalsResponse is only an internal public_data model name.
    for path in [
        "docs/02_4월_개인별_구현범위_수정안.md",
        "docs/agent_required_reading/02_4월_개인별_구현범위_수정안.md",
    ]:
        assert_contains(path, "BusArrivalsResponse` 계약")
        assert_contains(path, "내부 Pydantic 모델명은 `NormalizedBusArrivalsResponse`")
        assert_contains(path, "app-facing/shared contract의 공식 명칭은 `BusArrivalsResponse`")
        assert_not_contains(path, "bus_arrivals.response.schema.json`의 `NormalizedBusArrivalsResponse`를 따른다")
        assert_contains(path, '"routeId": "route502"')

    # The mock file is a sample; shared JSON Schema is the contract source of truth.
    assert_contains(
        "docs/read/프로젝트 4월분 개발에 관한 공통 프롬프트(AI 절대필독!).md",
        "busArrivals 표준 응답의 공식 계약은 `packages/shared_contracts/api/bus_arrivals.response.schema.json`",
    )
    assert_contains(
        "docs/read/프로젝트 4월분 개발에 관한 공통 프롬프트(AI 절대필독!).md",
        "mock_bus_arrivals.json`은 해당 계약을 따르는 검증용 샘플",
    )
    assert_not_contains(
        "docs/read/프로젝트 4월분 개발에 관한 공통 프롬프트(AI 절대필독!).md",
        "busArrivals 표준 응답은 services/public_data의 mock_bus_arrivals.json을 기준",
    )

    # Section numbering/order cleanup.
    assert_contains("docs/rw/SETUP.md", "## 17. 검증 및 테스트 실행")
    assert_not_contains("docs/rw/SETUP.md", "## 11. 검증 및 테스트 실행")
    assert_contains("docs/read/CONTRIBUTING.md", "### 1.3 문서 우선순위")
    assert_contains("docs/read/CONTRIBUTING.md", "위 표가 이 문서에서 사용하는 계약 영역별 우선순위의 최종 기준")
    assert_not_contains("docs/read/CONTRIBUTING.md", "## 2.1.1 계약 영역별 우선순위 분리")

    # Avoid an empty YAML null block in Flutter package metadata.
    assert_contains("packages/mobile_sensors/pubspec.yaml", "flutter: {}")
    assert_not_contains("packages/mobile_sensors/pubspec.yaml", "\nflutter:\n")


def validate_section7_carryover_doc_policy() -> None:
    assert_contains("docs/rw/README.md", "공통 프롬프트를 읽은 뒤")
    assert_not_contains("docs/rw/README.md", "공통 프롬프트가 추가된 후")
    assert_contains("docs/rw/README.md", ".docx` 파일은 전체 프로젝트 배경 이해에 도움이 되는 제출/공유용 보조 원문")
    assert_contains("docs/rw/README.md", "공식 계약·정합성 판단 기준은 markdown 문서와 machine-readable schema")
    assert_contains("docs/rw/MODULE_OWNERSHIP.md", "문서 기준과 참고 문서")
    assert_contains("docs/rw/MODULE_OWNERSHIP.md", "제출/공유용 참고 원문")
    assert_contains("docs/rw/MODULE_OWNERSHIP.md", "공식 계약·정합성 판단은 markdown 문서와 machine-readable schema")


def validate_section8_role_ownership_patch() -> None:
    priority_text = """1순위: 이 문서, docs/read/프로젝트 4월분 개발에 관한 공통 프롬프트(AI 절대필독!).md
2순위: 각 팀원별 에이전트 필독사항.md
3순위: docs/rw/선행작업의존성 정리.md
4순위: docs/02_4월_개인별_구현범위_수정안.md"""
    assert_contains("docs/read/프로젝트 4월분 개발에 관한 공통 프롬프트(AI 절대필독!).md", priority_text)
    assert_contains("docs/read/CONTRIBUTING.md", "3. docs/rw/선행작업의존성 정리.md\n4. docs/02_4월_개인별_구현범위_수정안.md")
    assert_contains("docs/read/CONTRIBUTING.md", "역할/범위/섹션 진행 기준의 3순위 문서")

    ownership = load_json("module_ownership.json")
    exceptions = ownership.get("limited_update_exceptions", {})
    if "docs/rw/공통 진행사항.md" not in exceptions or "docs/rw/선행작업의존성 정리.md" not in exceptions:
        raise AssertionError("module_ownership.json must document limited update exceptions")
    assert_contains("docs/rw/MODULE_OWNERSHIP.md", "## 4.2.1 공통 문서 제한적 최신화 예외")
    assert_contains("docs/rw/MODULE_OWNERSHIP.md", "자기 팀원 기록 공간만 수정 가능")
    assert_contains("docs/rw/MODULE_OWNERSHIP.md", "자신이 완료한 선행 섹션의 상태/산출물 정보만 제한적으로 최신화 가능")

    agent_required_paths = [
        "docs/read/윤현섭의 에이전트 필독사항.md",
        "docs/read/안준환의 에이전트 필독사항.md",
        "docs/read/심현석의 에이전트 필독사항.md",
        "docs/read/김도성의 에이전트 필독사항.md",
    ]
    for path in agent_required_paths:
        assert_contains(path, "docs/rw/선행작업의존성 정리.md           # 자신의 선행 섹션 상태/산출물 정보만 제한적으로 최신화")
        assert_contains(path, "3순위: docs/rw/선행작업의존성 정리.md")

    for path in [
        "docs/02_4월_개인별_구현범위_수정안.md",
        "docs/agent_required_reading/02_4월_개인별_구현범위_수정안.md",
    ]:
        assert_contains(path, "방위각 값을 패키지 내부 예제 또는 로그에 출력")
        assert_contains(path, "RSSI 값을 패키지 내부 예제 또는 로그에 출력할 수 있다")
        assert_contains(path, "실제 사용자/기사 앱 UI 수정은 윤현섭 담당")
        assert_not_contains(path, "방위각 값을 화면 또는 로그에 출력")
        assert_not_contains(path, "RSSI 값을 화면 또는 로그에 출력")

    assert_contains("docs/rw/PATCH_NOTES.md", "## section 8 role/ownership consistency patch")



def validate_section10_core_docs_patch() -> None:
    assert_contains("docs/rw/SETUP.md", "Unix/macOS/Linux:")
    assert_contains("docs/rw/SETUP.md", "Windows PowerShell:")
    assert_contains("docs/rw/SETUP.md", "5 passed")
    assert_not_contains("docs/rw/SETUP.md", "1 passed")
    assert_contains("docs/read/PACKAGE_MANIFEST.txt", "backend pytest: 5 passed")
    assert_not_contains("docs/read/PACKAGE_MANIFEST.txt", "backend pytest: 1 passed")
    assert_contains("docs/read/architecture_validation_result.txt", "- backend pytest: 5 passed")
    assert_not_contains("docs/read/architecture_validation_result.txt", "- backend pytest: 1 passed")
    assert_contains("docs/read/architecture_validation_result.txt", "Windows PowerShell equivalent:")
    assert_not_contains("docs/read/CONTRIBUTING.md", "해당 문서가 작성되기 전까지는 아래 임시 규칙을 사용한다")
    assert_contains("docs/read/CONTRIBUTING.md", "아래는 해당 문서의 핵심 요약 규칙이다")
    assert_contains("docs/rw/PATCH_NOTES.md", "## section 10 core documentation consistency patch")



def validate_section12_flutter_readme_clarity() -> None:
    passenger = "apps/passenger_app/README.md"
    driver = "apps/driver_app/README.md"

    # App README files should be app-specific, not a shared passenger/driver template.
    assert_contains(passenger, "윤현섭 담당 Flutter 사용자 앱 영역")
    assert_contains(passenger, "사용자 앱 스캐폴딩")
    assert_contains(passenger, "POST /geofence/check")
    assert_contains(passenger, "GET /bus-info/stops/{stopId}/arrivals")
    assert_contains(passenger, "POST /ride-requests")
    assert_contains(passenger, "STT/TTS")
    assert_contains(passenger, "mobi_mobile_sensors")
    assert_contains(passenger, "placeholder/mock 기반 UI shell")
    assert_contains(passenger, "기사 앱 UI와 기사 전용 탑승 요청 처리 화면은 `apps/driver_app`")
    assert_not_contains(passenger, "- `driver_app`: 버스 기사 전용 탑승 요청 확인 앱")

    assert_contains(driver, "윤현섭 담당 Flutter 기사 앱 영역")
    assert_contains(driver, "기사 전용 앱 스캐폴딩")
    assert_contains(driver, "FCM 클라이언트 수신 핸들러 연동")
    assert_contains(driver, "GET /drivers/{driverId}/ride-requests")
    assert_contains(driver, "PATCH /ride-requests/{requestId}/status")
    assert_contains(driver, "탑승 요청 상태 변경")
    assert_contains(driver, "`driver_app`은 `mobi_mobile_sensors`, `flutter_tts`, `speech_to_text`에 직접 의존하지 않는다")
    assert_contains(driver, "사용자 목적지 입력, STT/TTS 기반 사용자 안내, 승객용 지오펜싱 화면은 `apps/passenger_app`")
    assert_not_contains(driver, "- `passenger_app`: 시각장애인/노약자 사용자용 앱")
    assert_not_contains(driver, "목적지 입력을 위한 STT/TTS")

    assert_contains("docs/rw/PATCH_NOTES.md", "## section 12 Flutter app README clarity patch")


def validate_section14_backend_public_data_patch() -> None:
    # public_data normalized models must be as strict as the shared app-facing schema.
    schemas = "services/public_data/public_data_client/schemas.py"
    assert_contains(schemas, "from pydantic import BaseModel, ConfigDict, Field")
    assert_contains(schemas, "class StrictPublicDataModel(BaseModel):")
    assert_contains(schemas, 'model_config = ConfigDict(extra="forbid")')
    assert_contains(schemas, "class NormalizedBusArrival(StrictPublicDataModel):")
    assert_contains(schemas, "class NormalizedBusArrivalsResponse(StrictPublicDataModel):")
    assert_contains(schemas, "congestion: CongestionLevel")
    assert_not_contains(schemas, "congestion: CongestionLevel = CongestionLevel.UNKNOWN")

    # Public-data docs must point to the shared schema as the official output contract.
    public_readme = "services/public_data/README.md"
    assert_contains(public_readme, "## 표준 출력 계약")
    assert_contains(public_readme, "packages/shared_contracts/api/bus_arrivals.response.schema.json")
    assert_contains(public_readme, "표준 출력 객체는 `BusArrivalsResponse` 계약을 따른다")
    assert_contains(public_readme, "app-facing/backend-facing 출력에는 `stopName`, `source` 등 비계약 필드를 포함하지 않는다")
    assert_contains(public_readme, "명시적으로 `UNKNOWN`으로 표준화")
    assert_contains(public_readme, "정의되지 않은 extra field")

    # docs/02 copies must use the actual skeleton method name and avoid success/data wrapper wording.
    for path in [
        "docs/02_4월_개인별_구현범위_수정안.md",
        "docs/agent_required_reading/02_4월_개인별_구현범위_수정안.md",
    ]:
        assert_contains(path, "예상 클래스/메서드:")
        assert_contains(path, "BusArrivalsService.get_arrivals(stop_id)")
        assert_contains(path, "최종 응답 객체의 `arrivals[]`")
        assert_not_contains(path, "get_bus_arrivals(stop_id)")
        assert_not_contains(path, "최종 응답 wrapper")

    # SRS geofence examples must not keep prose inside the JSON code block.
    srs = read_text("docs/01_요구사항명세서.md")
    section = srs.split("### 6.4 지오펜싱 요청/응답 JSON", 1)[1].split("## 7. 외부 인터페이스 요구사항", 1)[0]
    if "Request 예시:" not in section or "Response 예시:" not in section:
        raise AssertionError("SRS geofence example must separate request and response code blocks")
    if section.count("```json") != 2 or section.count("```") != 4:
        raise AssertionError("SRS geofence request/response must use two clean JSON code blocks")
    after_last_code = section.rsplit("```", 1)[-1]
    if "`eventId`는 이벤트가 생성되지 않은 경우 `null`" not in after_last_code:
        raise AssertionError("SRS eventId explanation must be outside JSON code block")

    assert_contains("docs/rw/PATCH_NOTES.md", "## section 14 backend/public-data contract patch")


def validate_section16_sensors_future_scope_patch() -> None:
    # future_modules/spatial_audio should be future-only, not an optional April implementation.
    spatial = "future_modules/spatial_audio/README.md"
    assert_contains(spatial, "4월에는 실제 HRTF/3D 렌더링을 구현하지 않습니다")
    assert_contains(spatial, "향후 공간음향 기능을 위한 placeholder/계약 프레임만 보존")
    assert_not_contains(spatial, "구현을 강제하지 않습니다")

    # ai_vision should be clearly scoped to research/planning artifacts for April.
    ai = "ai_vision/README.md"
    assert_contains(ai, "4월에는 실제 모델 학습/추론 코드나 Flutter/백엔드 실시간 통합을 구현하지 않습니다")
    assert_contains(ai, "데이터 수집 계획, 라벨링 기준, 모델 후보 리서치, 향후 파이프라인 초안 작성")
    assert_not_contains(ai, "실제 AI 모델 완성보다")

    # SRS sensor requirements should not imply 안준환 may modify Flutter app UI directly.
    srs = "docs/01_요구사항명세서.md"
    assert_contains(srs, "센서 모듈은 스마트폰의 나침반/방향 값을 읽고 패키지 내부 예제 또는 로그에 표시")
    assert_contains(srs, "패키지 내부 예제 또는 함수 수준에서 스캔 시작/중지가 가능")
    assert_contains(srs, "실제 사용자/기사 앱 화면 반영은 윤현섭 담당 앱 영역")
    assert_not_contains(srs, "로그 또는 화면에 표시")
    assert_not_contains(srs, "스캔 시작/중지 버튼 또는 함수")

    # future head-tracking enum is a reserved future-only event enum.
    head = "future_modules/head_tracking/README.md"
    assert_contains(head, "future_head_tracking_status")
    assert_contains(head, "향후 센서 상태 이벤트용 예약 enum")
    assert_contains(head, "4월에는 앱/backend 이벤트로 발행하지 않습니다")
    assert_contains(head, "head_tracking_event.schema.json")
    assert_contains(head, "yaw`/`pitch`/`roll")

    assert_contains("docs/rw/PATCH_NOTES.md", "## section 16 sensors/future-modules scope patch")


def validate_section18_operations_packaging_patch() -> None:
    assert_contains("docs/rw/PATCH_NOTES.md", "## section 18 operations/packaging validation patch")
    assert_contains("docs/read/PACKAGE_MANIFEST.txt", "[Section 18 operations/packaging validation patch]")
    assert_contains("docs/read/architecture_validation_result.txt", "Section 18 validation additions:")

    validator = read_text("scripts/validate_architecture.py")
    for needle in [
        "listed - actual",
        "actual - listed",
        "docs/read/FINAL_FILE_LIST.txt omits packaged files",
        "node_modules",
        ".dart_tool",
        ".firebase",
        ".gcloud",
        "logs",
        "validate_codeowners_alignment",
    ]:
        if needle not in validator:
            raise AssertionError(f"section 18 validator hardening missing: {needle}")

    pr_template = read_text(".github/pull_request_template.md")
    for needle in [
        "## 4. 담당 범위 확인",
        "## 5. 선행작업 의존성 확인",
        "## 7. 충돌 이슈",
        "## 8. 문서 최신화",
        "## 10. 병합 전 주의사항",
        "최종 개발 보고서 최신화",
        "docs/rw/선행작업의존성 정리.md",
        "관련 없음",
    ]:
        if needle not in pr_template:
            raise AssertionError(f"section 18 PR template alignment missing: {needle}")
    if "충돌 가능성" in pr_template or "## 9. 비고" in pr_template:
        raise AssertionError("section 18 PR template must not keep obsolete weak headings")



def validate_section20_final_patch() -> None:
    assert_contains("docs/rw/PATCH_NOTES.md", "## section 20 final consistency patch")
    assert_contains("docs/read/PACKAGE_MANIFEST.txt", "[Section 20 final consistency patch]")
    assert_contains("docs/read/architecture_validation_result.txt", "Section 20 validation additions:")

    rules = load_json("infrastructure/firebase/database.rules.json")
    _assert_strict_current_location_rule(
        rules["rules"]["users"]["$uid"]["currentLocation"].get(".validate", ""),
        "users/{uid}",
    )
    _assert_strict_current_location_rule(
        rules["rules"]["drivers"]["$driverId"]["currentLocation"].get(".validate", ""),
        "drivers/{driverId}",
    )

    for path in [
        "docs/rw/ARCHITECTURE.md",
        "docs/rw/SETUP.md",
        "docs/rw/ENVIRONMENT_VARIABLES.md",
        "docs/02_4월_개인별_구현범위_수정안.md",
        "docs/agent_required_reading/02_4월_개인별_구현범위_수정안.md",
    ]:
        assert_contains(path, "실제 모델 학습/추론 코드")
        if path != "docs/rw/ENVIRONMENT_VARIABLES.md":
            assert_contains(path, "Flutter/백엔드 실시간 통합")
    assert_contains("docs/01_요구사항명세서.md", "실제 AI 비전 모델 학습/추론 코드")
    assert_contains("docs/01_요구사항명세서.md", "Flutter/백엔드 실시간 통합")
    assert_not_contains("docs/rw/ARCHITECTURE.md", "실제 AI 모델 완성보다는")
    assert_not_contains("docs/rw/SETUP.md", "실제 AI 모델 완성이 목표가 아니다")
    assert_not_contains("docs/rw/ENVIRONMENT_VARIABLES.md", "실제 모델 학습/추론이 필수 범위가 아니지만")
    for path in [
        "docs/02_4월_개인별_구현범위_수정안.md",
        "docs/agent_required_reading/02_4월_개인별_구현범위_수정안.md",
    ]:
        assert_not_contains(path, "4월 말까지 완성형 AI 모델을 만들 필요는 없다")


def main() -> None:
    validate_section20_final_patch()
    validate_section18_operations_packaging_patch()
    validate_section16_sensors_future_scope_patch()
    validate_section14_backend_public_data_patch()
    validate_section12_flutter_readme_clarity()
    validate_section10_core_docs_patch()
    validate_section8_role_ownership_patch()
    validate_section7_carryover_doc_policy()
    validate_v9_minor_consistency_cleanup()
    validate_v8_service_datetime_and_env()
    validate_v8_policy_docs()
    validate_v8_srs_examples_and_reading_order()
    validate_required_paths()
    validate_no_generated_ignored_files()
    validate_v6_doc_contract_cleanup()
    validate_v7_remaining_consistency()
    validate_openapi_contract_notice()
    validate_priority_and_scope_docs()
    validate_data_schema_examples_align_rtdb()
    validate_stale_path_examples_removed()
    validate_flutter_structure_docs()
    validate_driver_notification_todo()
    validate_docs02_current_structure()
    validate_srs_official_paths_and_examples()
    validate_json_schema_strictness()
    validate_setup_and_patch_notes_current()
    validate_agent_reading_prompt()
    validate_srs_single_source()
    validate_api_contracts()
    validate_shared_schemas()
    validate_backend_schema_alignment()
    validate_geofence_schema_alignment()
    validate_mobile_sensor_contracts()
    validate_enum_consistency()
    validate_runtime_constraints()
    validate_fcm_and_firebase_policy()
    validate_setup_and_env()
    validate_dependency_wording()
    validate_pr_template()
    validate_ownership()
    validate_codeowners_alignment()
    validate_meta_document_consistency()
    validate_manifest()
    print("Architecture validation: PASS")


if __name__ == "__main__":
    main()

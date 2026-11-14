"""Prepare the NORMAL Passenger Android APK. No login/cloud/ADB operation.

Accepts public Android Firebase app configuration, never Admin credentials.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import zipfile
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "apps/passenger_app"
PACKAGE = "com.example.mobi_passenger_app"
KEYS = {"MOBI_API_BASE_URL", "MOBI_FIREBASE_API_KEY", "MOBI_FIREBASE_APP_ID",
        "MOBI_FIREBASE_MESSAGING_SENDER_ID", "MOBI_FIREBASE_PROJECT_ID", "MOBI_FIREBASE_AUTH_DOMAIN", "MOBI_BLE_LOCAL_DEMO_MAPPING"}


def read_object(path: Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(value, dict) or any(k in value for k in ("private_key", "client_email", "refresh_token")):
        raise ValueError("Use public Android app settings, not service-account or login credentials")
    return value


def from_google_services(value: dict) -> dict[str, str]:
    project = value.get("project_info", {})
    clients = [c for c in value.get("client", []) if
        c.get("client_info", {}).get("android_client_info", {}).get("package_name") == PACKAGE]
    if len(clients) != 1:
        raise ValueError("google-services.json must contain exactly the NORMAL Passenger Android package")
    client = clients[0]
    keys = [k.get("current_key") for k in client.get("api_key", []) if k.get("current_key")]
    if len(keys) != 1:
        raise ValueError("One Android Firebase API key is required")
    return {"MOBI_FIREBASE_API_KEY": keys[0],
            "MOBI_FIREBASE_APP_ID": client["client_info"]["mobilesdk_app_id"],
            "MOBI_FIREBASE_PROJECT_ID": project["project_id"],
            "MOBI_FIREBASE_MESSAGING_SENDER_ID": project["project_number"]}


def validate_ble_demo(value: dict) -> dict:
    if (set(value) != {"schemaVersion", "identifierField", "entries"}
            or value.get("schemaVersion") != 1
            or value.get("identifierField") != "android.remoteId"
            or not isinstance(value.get("entries"), list) or len(value["entries"]) > 32):
        raise ValueError("Invalid local BLE demonstration mapping")
    used, entries = set(), []
    for row in value["entries"]:
        if not isinstance(row, dict) or set(row) != {"beaconId", "busId", "routeNo"}:
            raise ValueError("BLE mapping requires beaconId, busId and routeNo")
        if any(not isinstance(row[k], str) or not row[k].strip() for k in row):
            raise ValueError("Actual identifiers are required; no placeholder IDs")
        address = row["beaconId"].strip().replace("-", ":").upper()
        if (not re.fullmatch(r"[0-9A-F]{2}(?::[0-9A-F]{2}){5}", address)
                or address in used or len(row["busId"]) > 128 or len(row["routeNo"]) > 64):
            raise ValueError("Invalid or duplicate Android remoteId mapping")
        used.add(address)
        entries.append({"beaconId": address, "busId": row["busId"].strip(), "routeNo": row["routeNo"].strip()})
    return {"schemaVersion": 1, "identifierField": "android.remoteId", "entries": entries}


def validate(settings: dict) -> dict[str, str]:
    if set(settings) - KEYS:
        raise ValueError("Only normal app configuration is accepted; test/auth/producer/admin defines are forbidden")
    required = KEYS - {"MOBI_FIREBASE_AUTH_DOMAIN", "MOBI_BLE_LOCAL_DEMO_MAPPING"}
    if not required.issubset(settings) or any(not isinstance(v, str) for v in settings.values()):
        raise ValueError("Missing public Android Firebase settings or Backend URL")
    if any(not settings[k].strip() or "REPLACE" in settings[k] for k in required):
        raise ValueError("Replace all template fields before building a login-enabled app")
    app_id = settings["MOBI_FIREBASE_APP_ID"]
    sender = settings["MOBI_FIREBASE_MESSAGING_SENDER_ID"]
    if not re.fullmatch(r"1:[0-9]+:android:[a-fA-F0-9]+", app_id) or app_id.split(":")[1] != sender:
        raise ValueError("Use the Android app ID and matching sender number, not a Web app ID")
    if settings["MOBI_FIREBASE_PROJECT_ID"].startswith("demo-"):
        raise ValueError("The normal Android app cannot use demo/Fake authentication")
    url = urlsplit(settings["MOBI_API_BASE_URL"])
    if (url.scheme not in {"http", "https"} or not url.hostname or url.username or url.password
            or url.query or url.fragment or url.path not in {"", "/"}):
        raise ValueError("Backend must be an HTTP(S) origin without credentials, path, query or fragment")
    try:
        if url.port is not None and not 1 <= url.port <= 65535:
            raise ValueError("Invalid Backend port")
    except ValueError:
        raise ValueError("Invalid Backend port") from None
    if url.scheme == "http" and url.hostname != "127.0.0.1":
        raise ValueError("Debug HTTP supports only 127.0.0.1 via adb reverse; use HTTPS otherwise")
    if "MOBI_BLE_LOCAL_DEMO_MAPPING" in settings:
        validate_ble_demo(json.loads(settings["MOBI_BLE_LOCAL_DEMO_MAPPING"]))
    return dict(settings)



def build_source_info() -> dict:
    """Best-effort source identity, without paths, diffs or configuration values."""
    try:
        commit = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, stderr=subprocess.DEVNULL,
            timeout=10).decode().strip()
        dirty = bool(subprocess.check_output(
            ["git", "status", "--porcelain"], cwd=ROOT,
            stderr=subprocess.DEVNULL, timeout=10).strip())
        return {"gitCommit": commit, "workingTreeDirty": dirty}
    except (OSError, subprocess.SubprocessError):
        return {"gitCommit": None, "workingTreeDirty": None}


def write_build_info(apk: Path, settings: dict, source: dict) -> Path:
    """Describe bytes actually packaged. This is NOT runtime/device validation.

    Never serialize the settings dictionary, Firebase keys, device identifiers,
    local paths, or claims about the deployed provider's live/mock mode.
    """
    settings = validate(settings)
    models = []
    with zipfile.ZipFile(apk) as archive:
        for name in sorted(archive.namelist()):
            if name.startswith("assets/flutter_assets/assets/models/") and name.endswith(".tflite"):
                data = archive.read(name)
                models.append({"asset": name, "sizeBytes": len(data),
                               "sha256": hashlib.sha256(data).hexdigest()})
    if not models:
        raise ValueError("Built APK has no packaged camera model")
    commit = source.get("gitCommit")
    if commit is not None and not re.fullmatch(r"[0-9a-f]{40,64}", commit):
        raise ValueError("Invalid source identity")
    dirty = source.get("workingTreeDirty")
    if dirty is not None and not isinstance(dirty, bool):
        raise ValueError("Invalid working-tree state")
    info = {
        "schemaVersion": 1,
        "artifact": {"fileName": apk.name, "sizeBytes": apk.stat().st_size,
                     "sha256": hashlib.sha256(apk.read_bytes()).hexdigest()},
        "build": {"type": "debug", "entrypoint": "lib/main.dart",
                  "configuredPackage": PACKAGE, "authentication": "normal"},
        "source": {"gitCommit": commit, "workingTreeDirty": dirty},
        "backend": {"configuredOrigin": settings["MOBI_API_BASE_URL"],
                    "observedDataMode": "UNKNOWN", "connectivityChecked": False},
        "models": models,
        "verificationScope": "Build bytes only; no signature, device, acoustic, network, or live-data validation",
    }
    path = apk.with_suffix(".build-info.json")
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(info, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)
    return path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--settings", type=Path, help="Dart define JSON containing public app settings")
    source.add_argument("--google-services", type=Path, help="Existing Android public google-services.json")
    parser.add_argument("--backend-url", help="USB development: http://127.0.0.1:8000")
    parser.add_argument("--ble-demo-mapping", type=Path, help="Explicit local demonstration Android remoteId to bus mapping JSON; debug only")
    parser.add_argument("--build", action="store_true", help="Build normal main.dart debug APK; does NOT install or launch")
    parser.add_argument("--flutter", help="Path to flutter.bat when Flutter is not on PATH")
    args = parser.parse_args()
    try:
        settings = from_google_services(read_object(args.google_services)) if args.google_services else read_object(args.settings)
        if args.backend_url:
            settings["MOBI_API_BASE_URL"] = args.backend_url
        if args.ble_demo_mapping:
            mapping = validate_ble_demo(read_object(args.ble_demo_mapping))
            settings["MOBI_BLE_LOCAL_DEMO_MAPPING"] = json.dumps(mapping, ensure_ascii=False)
            print("BLE_LOCAL_DEMO_MAPPING:", len(mapping["entries"]), "entries; not an operating vehicle registry")
        settings = validate(settings)
        print("CONFIGURATION_VALID: normal Android app; public app settings only. No Firebase connection performed.")
        if not args.build:
            return 0
        flutter = args.flutter or shutil.which("flutter")
        if not flutter or not Path(flutter).is_file():
            raise ValueError("Flutter not found; provide --flutter with the local Flutter executable")
        target = APP / "build/passenger-config/normal-android.json"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(settings, ensure_ascii=False), encoding="utf-8")
        source_info = build_source_info()
        result = subprocess.run([str(flutter), "build", "apk", "--debug", "--no-pub",
            "--target", "lib/main.dart", "--dart-define-from-file=" + str(target)], cwd=APP)
        if result.returncode:
            return result.returncode
        apk = APP / "build/app/outputs/flutter-apk/app-debug.apk"
        print("APK_BUILT:", apk)
        print("APK_SHA256:", hashlib.sha256(apk.read_bytes()).hexdigest())
        print("BUILD_INFO:", write_build_info(apk, settings, source_info))
        print("Not installed/launched. Login requires separate Firebase access approval.")
        return 0
    except (ValueError, OSError, KeyError, TypeError, zipfile.BadZipFile):
        # Configuration values (including malformed credential files) are never echoed.
        print("CONFIGURATION_BLOCKED: check file type, Android package/app ID, required fields, Backend URL and optional local BLE mapping.")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

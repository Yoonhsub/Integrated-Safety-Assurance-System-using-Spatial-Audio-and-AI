"""Prepare/build/seed the explicit loopback-only Firebase emulator demo."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

from prepare_firebase_deployment import ROOT, copy_files, reserve_output

PROJECT = "demo-mobi-local"
ENVIRONMENT = {
    "APP_ENV": "local-demo", "MOBI_LOCAL_DEMO": "1",
    "FIREBASE_PROJECT_ID": PROJECT, "GOOGLE_CLOUD_PROJECT": PROJECT,
    "FIREBASE_AUTH_EMULATOR_HOST": "127.0.0.1:9099",
    "FIREBASE_DATABASE_EMULATOR_HOST": "127.0.0.1:9000",
    "FIREBASE_DATABASE_URL": f"https://{PROJECT}-default-rtdb.firebaseio.com",
    "FIREBASE_USE_MOCK": "false", "FIREBASE_USE_ADC": "false",
    "FIREBASE_SERVICE_ACCOUNT_PATH": "", "GOOGLE_APPLICATION_CREDENTIALS": "",
    "PUBLIC_DATA_USE_MOCK": "true", "FCM_ENABLED": "false", "FCM_USE_MOCK": "true",
    "GEMINI_API_KEY": "", "OPENAI_API_KEY": "", "GOOGLE_API_KEY": "",
    "BACKEND_CORS_ORIGINS": "http://127.0.0.1:5173,http://127.0.0.1:5174",
    "PYTHONDONTWRITEBYTECODE": "1",
}
ACCOUNTS = (
    ("demo-passenger-a", "passenger", None, None, None),
    ("demo-passenger-b", "passenger", None, None, None),
    ("demo-driver-a", "driver", "demo-driver-502", "MOCK-502", "502"),
    ("demo-driver-b", "driver", "demo-driver-105", "MOCK-105", "105"),
)
PASSWORD = "LocalDemo123!"  # disposable emulator-only accounts, never real credentials


def configure_environment() -> None:
    if os.getenv("K_SERVICE") or os.getenv("GAE_ENV"):
        raise ValueError("Local demo cannot run in a cloud runtime")
    os.environ.update(ENVIRONMENT)
    sys.path.insert(0, str(ROOT / "backend/api"))


def prepare(output: Path) -> None:
    reserve_output(output)
    shutil.copy2(ROOT / "infrastructure/firebase/emulators.config.json", output / "firebase.json")
    shutil.copy2(ROOT / "infrastructure/firebase/database.rules.json", output / "database.rules.json")
    workspace = output / "flutter-workspace"
    for rel in ("packages/mobile_auth", "packages/mobile_sensors", "apps/passenger_app", "apps/driver_app"):
        destination = workspace / rel
        destination.mkdir(parents=True)
        for filename in ("pubspec.yaml", "pubspec.lock", "analysis_options.yaml"):
            if (ROOT / rel / filename).is_file():
                shutil.copy2(ROOT / rel / filename, destination / filename)
        for folder, suffixes in (("lib", {".dart"}), ("test", {".dart"}),
                                 ("web", {".html", ".json", ".png", ".ico", ".js"}),
                                 ("assets", {".mp3", ".wav", ".json", ".png", ".frag"})):
            copy_files(ROOT / rel / folder, destination / folder, suffixes)
    for index, name in enumerate(("passenger", "driver"), 1):
        config = {
            "MOBI_FIREBASE_API_KEY": "demo-local-api-key",
            "MOBI_FIREBASE_APP_ID": f"1:123456789:web:local{index}",
            "MOBI_FIREBASE_MESSAGING_SENDER_ID": "123456789",
            "MOBI_FIREBASE_PROJECT_ID": PROJECT,
            "MOBI_FIREBASE_AUTH_DOMAIN": f"{PROJECT}.firebaseapp.com",
            "MOBI_API_BASE_URL": "http://127.0.0.1:8001", "MOBI_LOCAL_DEMO": "true",
        }
        (output / f"{name}-defines.json").write_text(json.dumps(config, indent=2), encoding="utf-8")
    (output / "local-demo.json").write_text(json.dumps({
        "project": PROJECT, "local_only": True, "source": str(ROOT),
        "passenger": "http://127.0.0.1:5173", "driver": "http://127.0.0.1:5174",
        "simulation": "Synthetic routes and assignments; no real boarding authorization",
    }, indent=2), encoding="utf-8")


def build(output: Path, flutter: str) -> None:
    marker = json.loads((output / "local-demo.json").read_text(encoding="utf-8"))
    if marker.get("project") != PROJECT or marker.get("local_only") is not True:
        raise ValueError("Not a local demo workspace")
    for name in ("passenger", "driver"):
        app = output / "flutter-workspace/apps" / f"{name}_app"
        subprocess.run([flutter, "pub", "get", "--enforce-lockfile"], cwd=app, check=True)
        subprocess.run([flutter, "build", "web", "--release", "--no-pub", "--base-href=/",
                        f"--dart-define-from-file={output / (name + '-defines.json')}"], cwd=app, check=True)


def seed() -> None:
    configure_environment()
    from firebase_admin import auth
    from app.security import firebase_auth_app
    from app.services.firebase_client import get_firebase_client
    app = firebase_auth_app()
    storage = get_firebase_client()
    for uid, role, driver_id, route_id, bus_no in ACCOUNTS:
        try:
            auth.get_user(uid, app=app)
        except auth.UserNotFoundError:
            auth.create_user(uid=uid, email=f"{uid}@example.test", password=PASSWORD, app=app)
        claims = {"mobi_role": role}
        if driver_id:
            claims["mobi_driver_id"] = driver_id
            storage.set(f"/drivers/{driver_id}", {"routeId": route_id, "busNo": bus_no, "simulation": True})
            storage.set(f"/localDemoAssignments/{route_id}", {
                "driverId": driver_id, "busNo": bus_no, "simulation": True,
            })
        auth.set_custom_user_claims(uid, claims, app=app)
    print("Seeded 4 emulator accounts and 2 synthetic driver assignments. Production unchanged.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "build", "seed", "backend"))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--flutter", default=shutil.which("flutter") or "flutter")
    args = parser.parse_args()
    if args.action in {"prepare", "build"} and args.output is None:
        parser.error("--output required")
    if args.action == "prepare":
        prepare(args.output.resolve())
    elif args.action == "build":
        build(args.output.resolve(), args.flutter)
    elif args.action == "seed":
        seed()
    else:
        configure_environment()
        import uvicorn
        uvicorn.run("app.local_demo:create_app", factory=True, host="127.0.0.1", port=8001,
                    workers=1, proxy_headers=False)


if __name__ == "__main__":
    main()

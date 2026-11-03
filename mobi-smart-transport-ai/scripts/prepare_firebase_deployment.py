"""Prepare deployment files outside the checkout. Never deploy or change cloud state."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
PROJECT = "mobi-smart-transport"
sys.path.insert(0, str(ROOT / "backend/api"))
from app.cloud_test import validate_web_app
DEFINE_KEYS = {
    "MOBI_FIREBASE_API_KEY", "MOBI_FIREBASE_APP_ID", "MOBI_FIREBASE_MESSAGING_SENDER_ID",
    "MOBI_FIREBASE_PROJECT_ID", "MOBI_FIREBASE_AUTH_DOMAIN",
}


def load_defines(path: Path, app_name: str | None = None) -> dict[str, str]:
    data = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(data, dict) or set(data) != DEFINE_KEYS:
        raise ValueError("Defines must contain only the five public Firebase web configuration keys")
    if any(not isinstance(v, str) or not v.strip() or "<" in v for v in data.values()):
        raise ValueError("Replace all web configuration placeholders")
    if data["MOBI_FIREBASE_PROJECT_ID"] != PROJECT:
        raise ValueError("Firebase project differs from the approved migration target")
    if app_name is not None:
        validate_web_app(data, app_name, PROJECT)
    return data


def reserve_output(output: Path) -> None:
    output = output.resolve()
    if output.is_relative_to(ROOT.parent) or ROOT.parent.is_relative_to(output):
        raise ValueError("Deployment output must be outside the repository")
    if output.exists():
        raise ValueError("Output already exists; choose a fresh directory")
    output.mkdir(parents=True)


def copy_files(source: Path, target: Path, suffixes: set[str]) -> None:
    for path in source.rglob("*"):
        if path.is_symlink():
            raise ValueError("Deployment source cannot contain symbolic links")
        if any(part in {"__pycache__", ".dart_tool", "build", ".git"} for part in path.relative_to(source).parts):
            continue
        if path.is_file() and path.suffix in suffixes:
            destination = target / path.relative_to(source)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, destination)


def prepare_backend(output: Path) -> None:
    reserve_output(output)
    for rel in ("backend/api/app", "services/public_data/public_data_client"):
        copy_files(ROOT / rel, output / rel, {".py"})
    copy_files(ROOT / "services/public_data/examples", output / "services/public_data/examples", {".json"})
    shutil.copy2(ROOT / "backend/api/requirements.txt", output / "backend/api/requirements.txt")
    # Root-location marker only; no local .env or service-account material is uploaded.
    (output / ".env.example").write_text("# Deployment root marker. Runtime environment supplies configuration.\n", encoding="utf-8")
    shutil.copy2(ROOT / "infrastructure/cloud_run/Dockerfile", output / "Dockerfile")


def prepare_web(output: Path, passenger: Path, driver: Path, api_url: str, flutter: str) -> None:
    parsed = urlparse(api_url)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.hostname in {"localhost", "127.0.0.1"}
            or parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path not in {"", "/"}):
        raise ValueError("Supply the deployed API's HTTPS origin")
    configs = {"passenger": load_defines(passenger, "passenger"), "driver": load_defines(driver, "driver")}
    if configs["passenger"]["MOBI_FIREBASE_APP_ID"] == configs["driver"]["MOBI_FIREBASE_APP_ID"]:
        raise ValueError("Passenger and Driver must use their respective registered web app IDs")
    reserve_output(output)
    workspace = output / "flutter-workspace"
    for name in ("mobile_auth", "mobile_sensors"):
        rel = Path("packages") / name
        destination = workspace / rel
        destination.mkdir(parents=True)
        shutil.copy2(ROOT / rel / "pubspec.yaml", destination / "pubspec.yaml")
        copy_files(ROOT / rel / "lib", destination / "lib", {".dart"})
    for name, config in configs.items():
        rel = Path("apps") / f"{name}_app"
        destination = workspace / rel
        destination.mkdir(parents=True)
        for filename in ("pubspec.yaml", "pubspec.lock"):
            shutil.copy2(ROOT / rel / filename, destination / filename)
        copy_files(ROOT / rel / "lib", destination / "lib", {".dart"})
        copy_files(ROOT / rel / "web", destination / "web", {".html", ".json", ".png", ".ico", ".js"})
        copy_files(ROOT / rel / "assets", destination / "assets", {".mp3", ".wav", ".json", ".png", ".frag"})
        config["MOBI_API_BASE_URL"] = api_url.rstrip("/")
        defines_path = output / f"{name}-defines.json"
        defines_path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
        subprocess.run([flutter, "pub", "get", "--enforce-lockfile"], cwd=destination, check=True)
        subprocess.run([flutter, "build", "web", "--release", "--no-pub", f"--base-href=/{name}/",
                        f"--dart-define-from-file={defines_path}"], cwd=destination, check=True)
        shutil.copytree(destination / "build/web", output / "web" / name)
    finalize_web(output, api_url)


def finalize_web(output: Path, api_url: str) -> None:
    """Package completed builds; reserved .invalid origins remain compile checks only."""
    for name in ("passenger", "driver"):
        index = output / "web" / name / "index.html"
        if not index.is_file() or f'<base href="/{name}/">' not in index.read_text(encoding="utf-8"):
            raise ValueError(f"Missing web build or incorrect base href: {name}")
    shutil.copy2(ROOT / "infrastructure/firebase/landing.html", output / "web/index.html")
    validation_only = urlparse(api_url).hostname.endswith(".invalid")
    config_name = "firebase.compile-check.json" if validation_only else "firebase.json"
    shutil.copy2(ROOT / "infrastructure/firebase/hosting.config.json", output / config_name)
    (output / "build_report.json").write_text(json.dumps({
        "project": PROJECT, "api_origin": api_url.rstrip("/"), "deployed": False,
        "deployable": not validation_only,
        "hosting_public": "web", "apps": ["passenger", "driver"],
    }, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("component", choices=("backend", "web"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--passenger-defines", type=Path)
    parser.add_argument("--driver-defines", type=Path)
    parser.add_argument("--api-url")
    parser.add_argument("--flutter", default=shutil.which("flutter") or "flutter")
    args = parser.parse_args()
    if args.component == "backend":
        prepare_backend(args.output.resolve())
    else:
        if not all((args.passenger_defines, args.driver_defines, args.api_url)):
            parser.error("web needs --passenger-defines, --driver-defines and --api-url")
        prepare_web(args.output.resolve(), args.passenger_defines, args.driver_defines, args.api_url, args.flutter)
    print(f"Prepared locally (not deployed): {args.output.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

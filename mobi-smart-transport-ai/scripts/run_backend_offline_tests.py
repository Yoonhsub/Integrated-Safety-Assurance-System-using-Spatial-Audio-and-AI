"""Local fixture suite with a default HTTPX synchronous-client guard.

Not a network sandbox: explicit transports, AsyncClient, requests, urllib and
subprocesses are outside this guard. Run only reviewed tests, without service
credentials and without emulator/cloud opt-ins. Never deploys or starts devices.
"""
from __future__ import annotations
import os
from pathlib import Path
import sys
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
OPT_INS = ("MOBI_AUTH_RUNNER_EMULATOR_TESTS", "RUN_LOCAL_RIDE_CONCURRENCY", "RUN_LOCAL_VISION_LEDGER")


def require_fixture_mode(environment: dict) -> None:
    if any(environment.get(name) == "1" for name in OPT_INS):
        raise ValueError("Emulator/RTDB opt-in is enabled; use the separate explicit integration workflow")


def guarded_httpx_initializer(original, httpx):
    def initialize(client, *args, **kwargs):
        kwargs.setdefault("trust_env", False)
        if kwargs.get("transport") is None:
            def reject(request):
                raise RuntimeError("Default HTTPX network transport disabled in fixture tests")
            kwargs["transport"] = httpx.MockTransport(reject)
        return original(client, *args, **kwargs)
    return initialize


def main() -> int:
    try:
        require_fixture_mode(os.environ)
    except ValueError as error:
        print(str(error))
        return 2
    import httpx
    import pytest
    sys.dont_write_bytecode = True
    os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
    sys.path[:0] = [str(ROOT / "backend/api"), str(ROOT)]
    scratch = tempfile.mkdtemp(prefix="mobi-fixture-", dir=Path.home())
    print("Reviewed fixture tests only; default synchronous HTTPX blocked, not a complete network sandbox.")
    print("Fresh test scratch:", scratch)
    previous = Path.cwd()
    try:
        os.chdir(ROOT)
        with patch.object(httpx.Client, "__init__", guarded_httpx_initializer(httpx.Client.__init__, httpx)):
            return int(pytest.main(["-q", "-p", "no:cacheprovider", "--basetemp=" + scratch,
                                   "backend/api/tests", "services/public_data/tests"]))
    finally:
        os.chdir(previous)


if __name__ == "__main__":
    raise SystemExit(main())

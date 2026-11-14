import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
import httpx

SPEC = importlib.util.spec_from_file_location("offline_runner", Path(__file__).resolve().parents[1] / "run_backend_offline_tests.py")
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class OfflineRunnerTests(unittest.TestCase):
    def test_explicit_integration_opt_in_is_rejected(self):
        runner.require_fixture_mode({})
        for key in runner.OPT_INS:
            with self.subTest(key=key), self.assertRaises(ValueError):
                runner.require_fixture_mode({key: "1"})

    def test_default_sync_client_is_blocked_without_network(self):
        initialize = runner.guarded_httpx_initializer(httpx.Client.__init__, httpx)
        with patch.object(httpx.Client, "__init__", initialize):
            for options in [{}, {"transport": None}]:
                with httpx.Client(**options) as client, self.assertRaises(RuntimeError):
                    client.get("https://example.invalid/never-sent")

    def test_explicit_mock_transport_stays_usable(self):
        transport = httpx.MockTransport(lambda request: httpx.Response(200, json={"fixture": True}))
        initialize = runner.guarded_httpx_initializer(httpx.Client.__init__, httpx)
        with patch.object(httpx.Client, "__init__", initialize):
            with httpx.Client(transport=transport) as client:
                self.assertEqual(client.get("https://example.invalid/local").json(), {"fixture": True})


if __name__ == "__main__":
    unittest.main()

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

SPEC = importlib.util.spec_from_file_location("prepare_passenger_android", Path(__file__).resolve().parents[1] / "prepare_passenger_android.py")
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


def settings():
    return {
        "MOBI_API_BASE_URL": "https://example.invalid",
        "MOBI_FIREBASE_API_KEY": "not-a-real-key-DO-NOT-SERIALIZE",
        "MOBI_FIREBASE_APP_ID": "1:123:android:abc123",
        "MOBI_FIREBASE_MESSAGING_SENDER_ID": "123",
        "MOBI_FIREBASE_PROJECT_ID": "unit-test-project",
    }


class BuildInfoTests(unittest.TestCase):
    def test_manifest_describes_packaged_bytes_not_runtime_claims(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / "app-debug.apk"
            with zipfile.ZipFile(apk, "w") as archive:
                archive.writestr("assets/flutter_assets/assets/models/test.tflite", b"fixture-model")
            config = settings()
            config["MOBI_BLE_LOCAL_DEMO_MAPPING"] = json.dumps({"schemaVersion": 1, "identifierField": "android.remoteId", "entries": [{"beaconId": "AA:BB:CC:DD:EE:FF", "busId": "private-demo", "routeNo": "502"}]})
            output = module.write_build_info(apk, config, {"gitCommit": "a" * 40, "workingTreeDirty": True})
            text = output.read_text(encoding="utf-8")
            value = json.loads(text)
            self.assertEqual(value["artifact"]["sha256"], hashlib.sha256(apk.read_bytes()).hexdigest())
            self.assertEqual(value["models"][0]["sha256"], hashlib.sha256(b"fixture-model").hexdigest())
            self.assertEqual(value["backend"]["observedDataMode"], "UNKNOWN")
            self.assertFalse(value["backend"]["connectivityChecked"])
            self.assertTrue(value["source"]["workingTreeDirty"])
            for secret in [config["MOBI_FIREBASE_API_KEY"], "AA:BB:CC:DD:EE:FF", "private-demo", directory]:
                self.assertNotIn(secret, text)
            self.assertFalse(output.with_suffix(output.suffix + ".tmp").exists())

    def test_missing_models_fail_without_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / "app.apk"
            with zipfile.ZipFile(apk, "w") as archive:
                archive.writestr("AndroidManifest.xml", b"fixture")
            with self.assertRaises(ValueError):
                module.write_build_info(apk, settings(), {})
            self.assertFalse(apk.with_suffix(".build-info.json").exists())

    def test_unknown_source_remains_unknown(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / "app.apk"
            with zipfile.ZipFile(apk, "w") as archive:
                archive.writestr("assets/flutter_assets/assets/models/test.tflite", b"fixture")
            value = json.loads(module.write_build_info(apk, settings(), {}).read_text())
            self.assertIsNone(value["source"]["gitCommit"])
            self.assertIsNone(value["source"]["workingTreeDirty"])

    def test_configuration_forbids_auth_bypass_credentials_and_bad_origins(self):
        for key in ["MOBI_AUTH_ONLY", "MOBI_LOCAL_DEMO", "private_key", "refresh_token"]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                module.validate({**settings(), key: "forbidden"})
        for origin in ["https://user:password@example.invalid", "https://example.invalid?token=value", "http://example.invalid", "https://example.invalid/path"]:
            with self.subTest(origin=origin), self.assertRaises(ValueError):
                module.validate({**settings(), "MOBI_API_BASE_URL": origin})

    def test_demo_mapping_has_exact_unique_mac(self):
        base = {"schemaVersion": 1, "identifierField": "android.remoteId", "entries": [{"beaconId": "aa-bb-cc-dd-ee-ff", "busId": "demo", "routeNo": "502"}]}
        self.assertEqual(module.validate_ble_demo(base)["entries"][0]["beaconId"], "AA:BB:CC:DD:EE:FF")
        base["entries"].append(dict(base["entries"][0]))
        with self.assertRaises(ValueError):
            module.validate_ble_demo(base)


if __name__ == "__main__":
    unittest.main()

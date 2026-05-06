from fastapi.testclient import TestClient
from app.main import app


def test_health():
    client = TestClient(app)
    res = client.get("/health")
    assert res.status_code == 200
    assert res.json()["status"] == "ok"

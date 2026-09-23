import os

import pytest

os.environ["APP_VERSION"] = "1.2.3"
os.environ["APP_ENV"] = "test"

from app.main import app  # noqa: E402  (env precisa ser setado antes do import)


@pytest.fixture
def client():
    app.config["TESTING"] = True
    with app.test_client() as client:
        yield client


def test_health_returns_200(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.get_json() == {"status": "ok"}


def test_healthz_alias(client):
    resp = client.get("/healthz")
    assert resp.status_code == 200
    assert resp.get_json() == {"status": "ok"}


def test_info_returns_version_and_env(client):
    resp = client.get("/info")
    assert resp.status_code == 200
    data = resp.get_json()
    assert data["version"] == "1.2.3"
    assert data["environment"] == "test"
    assert "hostname" in data and len(data["hostname"]) > 0


def test_root_returns_message(client):
    resp = client.get("/")
    assert resp.status_code == 200
    assert "message" in resp.get_json()
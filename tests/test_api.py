from __future__ import annotations

from fastapi.testclient import TestClient

from familyd.app import create_app
from familyd.config import AppConfig, DayHours
from familyd.hours import HoursStatus


def make_client(tmp_path):
    cfg = AppConfig(
        timezone="America/New_York",
        parent_pin="4242",
        hours={
            "monday": DayHours(start="00:00", end="23:59"),
            "tuesday": DayHours(start="00:00", end="23:59"),
            "wednesday": DayHours(start="00:00", end="23:59"),
            "thursday": DayHours(start="00:00", end="23:59"),
            "friday": DayHours(start="00:00", end="23:59"),
            "saturday": DayHours(start="00:00", end="23:59"),
            "sunday": DayHours(start="00:00", end="23:59"),
        },
        session_durations=[15, 30, 60],
        dry_run_network=True,
        data_dir=str(tmp_path),
        static_dir="static",
        templates_dir="templates",
        secret_key="test-secret",
    )
    app = create_app(cfg)
    return TestClient(app), app


def test_health_and_kid_page(tmp_path):
    client, _ = make_client(tmp_path)
    assert client.get("/healthz").json()["status"] == "ok"
    page = client.get("/")
    assert page.status_code == 200
    assert "Family Computer" in page.text


def test_full_approval_api(tmp_path):
    client, app = make_client(tmp_path)
    # Ensure open regardless of wall clock
    app.state.policy.hours = lambda: HoursStatus(
        open=True,
        timezone="America/New_York",
        now_local="now",
        window_start="00:00",
        window_end="23:59",
        next_open_at=None,
        message="Open",
    )

    status = client.get("/api/status").json()
    assert status["computer_open"] is True

    created = client.post("/api/requests", json={"minutes": 15, "note": "test"}).json()
    assert created["status"] == "pending"

    bad = client.post("/api/parent/login", json={"pin": "0000"})
    assert bad.status_code == 403

    ok = client.post("/api/parent/login", json={"pin": "4242"})
    assert ok.status_code == 200

    dash = client.get("/api/parent/dashboard").json()
    assert len(dash["pending_requests"]) == 1

    approved = client.post(f"/api/parent/requests/{created['id']}/approve").json()
    assert approved["session"]["status"] == "active"

    status2 = client.get("/api/status").json()
    assert status2["session"]["active"] is True
    assert any(a["id"] == "web" for a in status2["activities"])

    client.post("/api/parent/session/end")
    status3 = client.get("/api/status").json()
    assert status3["session"]["active"] is False

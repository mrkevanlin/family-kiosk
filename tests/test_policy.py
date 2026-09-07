from __future__ import annotations

from datetime import datetime
from zoneinfo import ZoneInfo

from familyd.config import AppConfig, DayHours
from familyd.db import Database
from familyd.hours import computer_hours_status
from familyd.policy import PolicyService
from familyd.proxy import domain_matches


def _cfg(**kwargs) -> AppConfig:
    base = dict(
        timezone="America/New_York",
        parent_pin="9999",
        hours={
            "monday": DayHours(start="16:00", end="20:00"),
            "saturday": DayHours(start="09:00", end="20:00"),
        },
        session_durations=[15, 30, 60],
        dry_run_network=True,
        data_dir="data/test",
    )
    base.update(kwargs)
    return AppConfig.model_validate(base)


def test_hours_open_weekday_afternoon():
    cfg = _cfg()
    # Monday 2026-09-07 17:00 ET
    now = datetime(2026, 9, 7, 17, 0, tzinfo=ZoneInfo("America/New_York"))
    status = computer_hours_status(cfg, now)
    assert status.open is True
    assert "Open until" in status.message


def test_hours_closed_weekday_morning():
    cfg = _cfg()
    now = datetime(2026, 9, 7, 10, 0, tzinfo=ZoneInfo("America/New_York"))
    status = computer_hours_status(cfg, now)
    assert status.open is False
    assert "4:00 PM" in status.message or "opens at" in status.message.lower()


def test_domain_matches():
    allowed = ["ide.mblock.cc", "khanacademy.org"]
    assert domain_matches("ide.mblock.cc", allowed)
    assert domain_matches("cdn.khanacademy.org", ["khanacademy.org"])
    assert domain_matches("www.khanacademy.org", allowed)
    assert not domain_matches("evil.com", allowed)
    assert not domain_matches("khanacademy.org.evil.com", allowed)


def test_request_approve_flow(tmp_path):
    cfg = _cfg(data_dir=str(tmp_path))
    # Force open hours by using a Saturday afternoon
    db = Database(cfg.db_path)
    policy = PolicyService(cfg, db)

    # Monkeypatch hours via replacing method
    from familyd.hours import HoursStatus

    policy.hours = lambda: HoursStatus(
        open=True,
        timezone="America/New_York",
        now_local="2026-09-05 17:00",
        window_start="09:00",
        window_end="20:00",
        next_open_at=None,
        message="Open",
    )

    req = policy.create_internet_request(30, "science project")
    assert req["status"] == "pending"
    assert len(db.list_pending_requests()) == 1

    result = policy.approve_request(req["id"])
    assert result["session"]["status"] == "active"
    session = policy.refresh_session()
    assert session.active is True
    assert session.minutes == 30

    policy.end_session()
    assert policy.refresh_session().active is False


def test_pin():
    cfg = _cfg()
    db = Database(cfg.db_path)
    policy = PolicyService(cfg, db)
    assert policy.verify_pin("9999")
    assert not policy.verify_pin("0000")

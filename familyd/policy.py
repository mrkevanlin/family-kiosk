from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any
from zoneinfo import ZoneInfo

from familyd.config import AppConfig
from familyd.db import Database, utcnow_iso
from familyd.hours import HoursStatus, computer_hours_status
from familyd.network import apply_internet_policy


def _parse_iso(value: str) -> datetime:
    dt = datetime.fromisoformat(value)
    if dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt


@dataclass
class SessionView:
    active: bool
    minutes: int | None = None
    started_at: str | None = None
    ends_at: str | None = None
    remaining_seconds: int = 0

    def as_dict(self) -> dict[str, Any]:
        return {
            "active": self.active,
            "minutes": self.minutes,
            "started_at": self.started_at,
            "ends_at": self.ends_at,
            "remaining_seconds": self.remaining_seconds,
        }


class PolicyService:
    def __init__(self, cfg: AppConfig, db: Database) -> None:
        self.cfg = cfg
        self.db = db

    def hours(self) -> HoursStatus:
        return computer_hours_status(self.cfg)

    def refresh_session(self) -> SessionView:
        """Expire sessions that have run out; sync network policy."""
        row = self.db.get_active_session()
        if not row:
            apply_internet_policy(self.cfg, False)
            return SessionView(active=False)

        ends = _parse_iso(row["ends_at"])
        now = datetime.now(timezone.utc)
        remaining = int((ends - now).total_seconds())
        if remaining <= 0:
            self.db.end_active_session("expired")
            self.db.log_event("session_expired", f"session={row['id']}")
            apply_internet_policy(self.cfg, False)
            return SessionView(active=False)

        apply_internet_policy(self.cfg, True)
        # Present times in local timezone for UI.
        tz = ZoneInfo(self.cfg.timezone)
        return SessionView(
            active=True,
            minutes=row["minutes"],
            started_at=_parse_iso(row["started_at"]).astimezone(tz).isoformat(),
            ends_at=ends.astimezone(tz).isoformat(),
            remaining_seconds=remaining,
        )

    def kid_status(self) -> dict[str, Any]:
        hours = self.hours()
        session = self.refresh_session()
        pending = self.db.list_pending_requests()
        return {
            "computer_open": hours.open,
            "hours": {
                "open": hours.open,
                "message": hours.message,
                "now_local": hours.now_local,
                "window_start": hours.window_start,
                "window_end": hours.window_end,
                "next_open_at": hours.next_open_at,
                "timezone": hours.timezone,
            },
            "session": session.as_dict(),
            "pending_request": pending[0] if pending else None,
            "session_durations": self.cfg.session_durations,
            "mblock_url": self.cfg.mblock_url,
            "homework_start_url": self.cfg.homework_start_url,
            "homework_url_allowlist": self.cfg.homework_url_allowlist,
            "activities": self._activities(hours.open, session.active),
        }

    def _activities(self, computer_open: bool, internet_on: bool) -> list[dict[str, Any]]:
        if not computer_open:
            return []
        tiles = [
            {
                "id": "homework",
                "title": "Homework",
                "subtitle": "Google with SafeSearch on",
                "action": "launch_homework",
                "enabled": True,
            },
            {
                "id": "mblock",
                "title": "mBlock",
                "subtitle": "Coding & robots",
                "action": "launch_mblock",
                "enabled": True,
            },
            {
                "id": "ask_internet",
                "title": "Ask for internet",
                "subtitle": "Send a request to a parent",
                "action": "request_internet",
                "enabled": not internet_on,
            },
        ]
        if internet_on:
            tiles.append(
                {
                    "id": "web",
                    "title": "Web",
                    "subtitle": "Internet is on",
                    "action": "launch_web",
                    "enabled": True,
                }
            )
        return tiles

    def create_internet_request(self, minutes: int, note: str | None = None) -> dict[str, Any]:
        hours = self.hours()
        if not hours.open:
            raise ValueError("Computer is closed right now.")
        if minutes not in self.cfg.session_durations:
            raise ValueError(
                f"Minutes must be one of {self.cfg.session_durations}."
            )
        session = self.refresh_session()
        if session.active:
            raise ValueError("Internet is already on.")
        pending = self.db.list_pending_requests()
        if pending:
            raise ValueError("A request is already waiting for a parent.")
        req = self.db.create_request(minutes, note)
        self.db.log_event("request_created", f"id={req['id']} minutes={minutes}")
        return req

    def approve_request(self, request_id: int) -> dict[str, Any]:
        req = self.db.get_request(request_id)
        if not req:
            raise ValueError("Request not found.")
        if req["status"] != "pending":
            raise ValueError("Request is not pending.")
        hours = self.hours()
        if not hours.open:
            raise ValueError("Cannot approve while the computer is closed.")

        self.db.set_request_status(request_id, "approved")
        now = datetime.now(timezone.utc)
        ends = now + timedelta(minutes=req["minutes"])
        session = self.db.create_session(
            minutes=req["minutes"],
            started_at=now.replace(microsecond=0).isoformat(),
            ends_at=ends.replace(microsecond=0).isoformat(),
            request_id=request_id,
        )
        apply_internet_policy(self.cfg, True)
        self.db.log_event(
            "request_approved", f"id={request_id} session={session['id']}"
        )
        return {"request": self.db.get_request(request_id), "session": session}

    def deny_request(self, request_id: int) -> dict[str, Any]:
        req = self.db.get_request(request_id)
        if not req:
            raise ValueError("Request not found.")
        if req["status"] != "pending":
            raise ValueError("Request is not pending.")
        updated = self.db.set_request_status(request_id, "denied")
        self.db.log_event("request_denied", f"id={request_id}")
        return updated or {}

    def end_session(self) -> dict[str, Any] | None:
        ended = self.db.end_active_session("ended")
        apply_internet_policy(self.cfg, False)
        if ended:
            self.db.log_event("session_ended", f"id={ended['id']}")
        return ended

    def verify_pin(self, pin: str) -> bool:
        return pin == self.cfg.parent_pin

    def parent_dashboard(self) -> dict[str, Any]:
        hours = self.hours()
        session = self.refresh_session()
        return {
            "hours": {
                "open": hours.open,
                "message": hours.message,
                "now_local": hours.now_local,
                "next_open_at": hours.next_open_at,
            },
            "session": session.as_dict(),
            "pending_requests": self.db.list_pending_requests(),
            "recent_events": self.db.recent_events(15),
            "session_durations": self.cfg.session_durations,
        }

    def start_manual_session(self, minutes: int) -> dict[str, Any]:
        """Parent can grant internet without a kid request."""
        if minutes not in self.cfg.session_durations:
            raise ValueError(
                f"Minutes must be one of {self.cfg.session_durations}."
            )
        hours = self.hours()
        if not hours.open:
            raise ValueError("Computer is closed.")
        now = datetime.now(timezone.utc)
        ends = now + timedelta(minutes=minutes)
        session = self.db.create_session(
            minutes=minutes,
            started_at=now.replace(microsecond=0).isoformat(),
            ends_at=ends.replace(microsecond=0).isoformat(),
            request_id=None,
        )
        apply_internet_policy(self.cfg, True)
        self.db.log_event("manual_session", f"minutes={minutes}")
        return session

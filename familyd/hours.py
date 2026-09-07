from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, time, timedelta
from zoneinfo import ZoneInfo

from familyd.config import AppConfig, DayHours


DAY_NAMES = [
    "monday",
    "tuesday",
    "wednesday",
    "thursday",
    "friday",
    "saturday",
    "sunday",
]


def _parse_hhmm(value: str) -> time:
    hour, minute = value.split(":")
    return time(int(hour), int(minute))


def _fmt_time(dt: datetime) -> str:
    """Portable 12-hour time (GNU %-I is not available on macOS)."""
    hour = dt.hour % 12 or 12
    return f"{hour}:{dt.minute:02d} {'AM' if dt.hour < 12 else 'PM'}"


def _fmt_day_time(dt: datetime) -> str:
    return f"{dt.strftime('%A')} {_fmt_time(dt)}"


@dataclass
class HoursStatus:
    open: bool
    timezone: str
    now_local: str
    window_start: str | None
    window_end: str | None
    next_open_at: str | None
    message: str


def _local_now(cfg: AppConfig, now: datetime | None = None) -> datetime:
    tz = ZoneInfo(cfg.timezone)
    if now is None:
        return datetime.now(tz)
    if now.tzinfo is None:
        return now.replace(tzinfo=tz)
    return now.astimezone(tz)


def _window_for_day(cfg: AppConfig, day_name: str) -> DayHours | None:
    return cfg.hours.get(day_name)


def _combine(day: datetime, hhmm: str) -> datetime:
    t = _parse_hhmm(hhmm)
    return day.replace(hour=t.hour, minute=t.minute, second=0, microsecond=0)


def find_next_open(cfg: AppConfig, now: datetime | None = None) -> datetime | None:
    local = _local_now(cfg, now)
    for offset in range(0, 8):
        day = local + timedelta(days=offset)
        day_name = DAY_NAMES[day.weekday()]
        window = _window_for_day(cfg, day_name)
        if not window:
            continue
        start = _combine(day, window.start)
        end = _combine(day, window.end)
        if offset == 0:
            if local < start:
                return start
            if start <= local < end:
                return start  # already open; start of current window
            continue
        return start
    return None


def computer_hours_status(cfg: AppConfig, now: datetime | None = None) -> HoursStatus:
    local = _local_now(cfg, now)
    day_name = DAY_NAMES[local.weekday()]
    window = _window_for_day(cfg, day_name)

    if not window:
        nxt = find_next_open(cfg, local)
        return HoursStatus(
            open=False,
            timezone=cfg.timezone,
            now_local=local.strftime("%Y-%m-%d %H:%M"),
            window_start=None,
            window_end=None,
            next_open_at=_fmt_day_time(nxt) if nxt else None,
            message="The computer is closed today.",
        )

    start = _combine(local, window.start)
    end = _combine(local, window.end)
    is_open = start <= local < end

    if is_open:
        return HoursStatus(
            open=True,
            timezone=cfg.timezone,
            now_local=local.strftime("%Y-%m-%d %H:%M"),
            window_start=window.start,
            window_end=window.end,
            next_open_at=None,
            message=f"Open until {_fmt_time(end)}.",
        )

    nxt = find_next_open(cfg, local)
    if nxt:
        # Prefer friendly "back at 4:00 PM" for same-day reopen.
        if nxt.date() == local.date():
            when = _fmt_time(nxt)
            msg = f"The computer opens at {when}."
        else:
            when = _fmt_day_time(nxt)
            msg = f"Back {when}."
    else:
        when = None
        msg = "The computer is closed."

    return HoursStatus(
        open=False,
        timezone=cfg.timezone,
        now_local=local.strftime("%Y-%m-%d %H:%M"),
        window_start=window.start,
        window_end=window.end,
        next_open_at=when,
        message=msg,
    )

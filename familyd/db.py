from __future__ import annotations

import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator


SCHEMA = """
CREATE TABLE IF NOT EXISTS requests (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    minutes INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    created_at TEXT NOT NULL,
    resolved_at TEXT,
    note TEXT
);

CREATE TABLE IF NOT EXISTS sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    request_id INTEGER,
    minutes INTEGER NOT NULL,
    started_at TEXT NOT NULL,
    ends_at TEXT NOT NULL,
    ended_at TEXT,
    status TEXT NOT NULL DEFAULT 'active',
    FOREIGN KEY(request_id) REFERENCES requests(id)
);

CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL,
    detail TEXT,
    created_at TEXT NOT NULL
);
"""


def utcnow_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


class Database:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._init()

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.path, check_same_thread=False)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys = ON")
        return conn

    def _init(self) -> None:
        with self.connection() as conn:
            conn.executescript(SCHEMA)

    @contextmanager
    def connection(self) -> Iterator[sqlite3.Connection]:
        conn = self._connect()
        try:
            yield conn
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()

    def log_event(self, kind: str, detail: str | None = None) -> None:
        with self.connection() as conn:
            conn.execute(
                "INSERT INTO events (kind, detail, created_at) VALUES (?, ?, ?)",
                (kind, detail, utcnow_iso()),
            )

    def create_request(self, minutes: int, note: str | None = None) -> dict[str, Any]:
        with self.connection() as conn:
            cur = conn.execute(
                "INSERT INTO requests (minutes, status, created_at, note) VALUES (?, 'pending', ?, ?)",
                (minutes, utcnow_iso(), note),
            )
            row = conn.execute(
                "SELECT * FROM requests WHERE id = ?", (cur.lastrowid,)
            ).fetchone()
        return dict(row)

    def list_pending_requests(self) -> list[dict[str, Any]]:
        with self.connection() as conn:
            rows = conn.execute(
                "SELECT * FROM requests WHERE status = 'pending' ORDER BY created_at ASC"
            ).fetchall()
        return [dict(r) for r in rows]

    def get_request(self, request_id: int) -> dict[str, Any] | None:
        with self.connection() as conn:
            row = conn.execute(
                "SELECT * FROM requests WHERE id = ?", (request_id,)
            ).fetchone()
        return dict(row) if row else None

    def set_request_status(self, request_id: int, status: str) -> dict[str, Any] | None:
        with self.connection() as conn:
            conn.execute(
                "UPDATE requests SET status = ?, resolved_at = ? WHERE id = ?",
                (status, utcnow_iso(), request_id),
            )
            row = conn.execute(
                "SELECT * FROM requests WHERE id = ?", (request_id,)
            ).fetchone()
        return dict(row) if row else None

    def create_session(
        self, minutes: int, started_at: str, ends_at: str, request_id: int | None = None
    ) -> dict[str, Any]:
        with self.connection() as conn:
            # End any currently active session first.
            conn.execute(
                "UPDATE sessions SET status = 'ended', ended_at = ? WHERE status = 'active'",
                (started_at,),
            )
            cur = conn.execute(
                """
                INSERT INTO sessions (request_id, minutes, started_at, ends_at, status)
                VALUES (?, ?, ?, ?, 'active')
                """,
                (request_id, minutes, started_at, ends_at),
            )
            row = conn.execute(
                "SELECT * FROM sessions WHERE id = ?", (cur.lastrowid,)
            ).fetchone()
        return dict(row)

    def get_active_session(self) -> dict[str, Any] | None:
        with self.connection() as conn:
            row = conn.execute(
                "SELECT * FROM sessions WHERE status = 'active' ORDER BY id DESC LIMIT 1"
            ).fetchone()
        return dict(row) if row else None

    def end_active_session(self, reason: str = "ended") -> dict[str, Any] | None:
        now = utcnow_iso()
        with self.connection() as conn:
            row = conn.execute(
                "SELECT * FROM sessions WHERE status = 'active' ORDER BY id DESC LIMIT 1"
            ).fetchone()
            if not row:
                return None
            conn.execute(
                "UPDATE sessions SET status = ?, ended_at = ? WHERE id = ?",
                (reason, now, row["id"]),
            )
            updated = conn.execute(
                "SELECT * FROM sessions WHERE id = ?", (row["id"],)
            ).fetchone()
        return dict(updated) if updated else None

    def recent_events(self, limit: int = 20) -> list[dict[str, Any]]:
        with self.connection() as conn:
            rows = conn.execute(
                "SELECT * FROM events ORDER BY id DESC LIMIT ?", (limit,)
            ).fetchall()
        return [dict(r) for r in rows]

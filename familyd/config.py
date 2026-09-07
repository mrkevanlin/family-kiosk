from __future__ import annotations

import os
from functools import lru_cache
from pathlib import Path
from typing import Any

import yaml
from pydantic import BaseModel, Field


DEFAULT_CONFIG_PATHS = [
    Path(os.environ.get("FAMILY_KIOSK_CONFIG", "")),
    Path("config/config.yaml"),
    Path("config/config.example.yaml"),
    Path("/etc/family-kiosk/config.yaml"),
]


class DayHours(BaseModel):
    start: str  # HH:MM
    end: str


class AppConfig(BaseModel):
    timezone: str = "America/New_York"
    parent_pin: str = "1234"
    kid_username: str = "kid"
    hours: dict[str, DayHours] = Field(default_factory=dict)
    always_allow_domains: list[str] = Field(default_factory=list)
    homework_url_allowlist: list[str] = Field(default_factory=list)
    mblock_url: str = "https://ide.mblock.cc"
    session_durations: list[int] = Field(default_factory=lambda: [15, 30, 60])
    host: str = "0.0.0.0"
    port: int = 8787
    data_dir: str = "data"
    static_dir: str = "static"
    templates_dir: str = "templates"
    dry_run_network: bool = True
    secret_key: str = Field(
        default_factory=lambda: os.environ.get(
            "FAMILY_KIOSK_SECRET", "change-me-family-kiosk-dev-secret"
        )
    )

    @property
    def data_path(self) -> Path:
        return Path(self.data_dir)

    @property
    def db_path(self) -> Path:
        return self.data_path / "family.db"

    @property
    def static_path(self) -> Path:
        return Path(self.static_dir)

    @property
    def templates_path(self) -> Path:
        return Path(self.templates_dir)


def _first_existing(paths: list[Path]) -> Path | None:
    for path in paths:
        if path and str(path) and path.is_file():
            return path
    return None


def load_config(path: Path | None = None) -> AppConfig:
    config_path = path or _first_existing(DEFAULT_CONFIG_PATHS)
    if config_path is None:
        return AppConfig()
    with config_path.open("r", encoding="utf-8") as fh:
        raw: dict[str, Any] = yaml.safe_load(fh) or {}
    return AppConfig.model_validate(raw)


@lru_cache
def get_config() -> AppConfig:
    return load_config()


def reload_config() -> AppConfig:
    get_config.cache_clear()
    return get_config()

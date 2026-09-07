from __future__ import annotations

import asyncio
import logging
from contextlib import asynccontextmanager
from typing import Any, AsyncIterator

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel, Field
from starlette.middleware.sessions import SessionMiddleware

from familyd.config import AppConfig, get_config, load_config
from familyd.db import Database
from familyd.network import ensure_policy_bootstrap
from familyd.policy import PolicyService
from familyd.proxy import AllowlistProxy

log = logging.getLogger("familyd")


class RequestInternetBody(BaseModel):
    minutes: int
    note: str | None = None


class PinBody(BaseModel):
    pin: str = Field(min_length=1, max_length=32)


class ManualSessionBody(BaseModel):
    minutes: int


def create_app(cfg: AppConfig | None = None) -> FastAPI:
    cfg = cfg or get_config()
    db = Database(cfg.db_path)
    policy = PolicyService(cfg, db)
    proxy = AllowlistProxy(cfg.always_allow_domains)

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        logging.basicConfig(level=logging.INFO)
        cfg.data_path.mkdir(parents=True, exist_ok=True)
        # Restore session policy if one is still active; else block.
        session = policy.refresh_session()
        if not session.active:
            ensure_policy_bootstrap(cfg)
        try:
            await proxy.start()
        except OSError as exc:
            log.warning("Allowlist proxy not started: %s", exc)
        # Background expiry ticker
        stop = asyncio.Event()

        async def ticker() -> None:
            while not stop.is_set():
                try:
                    policy.refresh_session()
                except Exception:
                    log.exception("session refresh failed")
                try:
                    await asyncio.wait_for(stop.wait(), timeout=15)
                except asyncio.TimeoutError:
                    pass

        task = asyncio.create_task(ticker())
        yield
        stop.set()
        await task
        await proxy.stop()

    app = FastAPI(title="Family Kiosk", version="0.1.0", lifespan=lifespan)
    app.add_middleware(
        SessionMiddleware,
        secret_key=cfg.secret_key,
        session_cookie="family_kiosk_session",
        same_site="lax",
        https_only=False,
        max_age=60 * 60 * 12,
    )

    templates = Jinja2Templates(directory=str(cfg.templates_path))
    if cfg.static_path.is_dir():
        app.mount("/static", StaticFiles(directory=str(cfg.static_path)), name="static")

    def require_parent(request: Request) -> None:
        if not request.session.get("parent_ok"):
            raise HTTPException(status_code=401, detail="Parent PIN required")

    # ---------- Pages ----------

    @app.get("/", response_class=HTMLResponse)
    async def kid_home(request: Request) -> HTMLResponse:
        return templates.TemplateResponse(
            request,
            "kid.html",
            {"title": "Family Computer"},
        )

    @app.get("/parent", response_class=HTMLResponse)
    async def parent_home(request: Request) -> HTMLResponse:
        return templates.TemplateResponse(
            request,
            "parent.html",
            {
                "title": "Parent Dashboard",
                "authenticated": bool(request.session.get("parent_ok")),
            },
        )

    # ---------- Kid API ----------

    @app.get("/api/status")
    async def api_status() -> dict[str, Any]:
        return policy.kid_status()

    @app.post("/api/requests")
    async def api_create_request(body: RequestInternetBody) -> dict[str, Any]:
        try:
            return policy.create_internet_request(body.minutes, body.note)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

    @app.post("/api/launch/{activity}")
    async def api_launch(activity: str) -> dict[str, Any]:
        """Kid UI asks the kiosk wrapper to open an activity profile."""
        allowed = {"homework", "mblock", "web"}
        if activity not in allowed:
            raise HTTPException(status_code=400, detail="Unknown activity")
        status = policy.kid_status()
        if not status["computer_open"]:
            raise HTTPException(status_code=403, detail="Computer is closed")
        if activity == "web" and not status["session"]["active"]:
            raise HTTPException(status_code=403, detail="Internet session required")
        flag = cfg.data_path / "launch_activity"
        flag.write_text(activity, encoding="utf-8")
        db.log_event("launch", activity)
        return {
            "ok": True,
            "activity": activity,
            "mblock_url": cfg.mblock_url,
            "homework_urls": cfg.homework_url_allowlist,
        }

    @app.post("/api/parent/verify-pin")
    async def api_verify_pin(body: PinBody) -> dict[str, Any]:
        ok = policy.verify_pin(body.pin)
        return {"ok": ok}

    @app.post("/api/parent/exit-kiosk")
    async def api_exit_kiosk(body: PinBody) -> dict[str, Any]:
        """Kid UI calls this after PIN; install script maps it to session logout."""
        if not policy.verify_pin(body.pin):
            raise HTTPException(status_code=403, detail="Wrong PIN")
        # Write a flag the kiosk wrapper watches, or invoke loginctl when available.
        flag = cfg.data_path / "exit_kiosk.flag"
        flag.write_text("1", encoding="utf-8")
        db.log_event("exit_kiosk", "parent pin accepted")
        return {"ok": True, "action": "exit_kiosk"}

    # ---------- Parent API ----------

    @app.post("/api/parent/login")
    async def parent_login(request: Request, body: PinBody) -> dict[str, Any]:
        if not policy.verify_pin(body.pin):
            raise HTTPException(status_code=403, detail="Wrong PIN")
        request.session["parent_ok"] = True
        db.log_event("parent_login", None)
        return {"ok": True}

    @app.post("/api/parent/logout")
    async def parent_logout(request: Request) -> dict[str, Any]:
        request.session.clear()
        return {"ok": True}

    @app.get("/api/parent/dashboard")
    async def parent_dashboard(request: Request, _: None = Depends(require_parent)) -> dict[str, Any]:
        return policy.parent_dashboard()

    @app.post("/api/parent/requests/{request_id}/approve")
    async def parent_approve(
        request_id: int, request: Request, _: None = Depends(require_parent)
    ) -> dict[str, Any]:
        try:
            return policy.approve_request(request_id)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

    @app.post("/api/parent/requests/{request_id}/deny")
    async def parent_deny(
        request_id: int, request: Request, _: None = Depends(require_parent)
    ) -> dict[str, Any]:
        try:
            return policy.deny_request(request_id)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

    @app.post("/api/parent/session/end")
    async def parent_end_session(
        request: Request, _: None = Depends(require_parent)
    ) -> dict[str, Any]:
        ended = policy.end_session()
        return {"ended": ended}

    @app.post("/api/parent/session/start")
    async def parent_start_session(
        body: ManualSessionBody,
        request: Request,
        _: None = Depends(require_parent),
    ) -> dict[str, Any]:
        try:
            return policy.start_manual_session(body.minutes)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

    @app.get("/healthz")
    async def healthz() -> dict[str, str]:
        return {"status": "ok"}

    # Stash for tests
    app.state.cfg = cfg  # type: ignore[attr-defined]
    app.state.db = db  # type: ignore[attr-defined]
    app.state.policy = policy  # type: ignore[attr-defined]
    return app


app = create_app()


def main() -> None:
    import uvicorn

    cfg = load_config()
    uvicorn.run(
        "familyd.app:app",
        host=cfg.host,
        port=cfg.port,
        reload=False,
        factory=False,
    )


if __name__ == "__main__":
    main()

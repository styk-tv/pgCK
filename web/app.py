from __future__ import annotations

import os
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from web.protocol import build_browser_config, protocol_document, render_index, render_tasks_page
from web.service import BoardValidationError, build_live_board_service


BASE_DIR = Path(__file__).resolve().parent


def _resolve_cklib_dir() -> Path | None:
    """Locate CK.Lib.Js for mounting at /cklib.

    Resolution order:
      1. PGCK_CKLIB_DIR environment variable (explicit override).
      2. ./cklib next to the FastAPI module (OCI bundle layout per SPEC.OCI.BUNDLE.v0.2).
      3. ../../CK.Lib.Js (dev sibling checkout at pgCK repo level).
    """
    override = os.getenv("PGCK_CKLIB_DIR")
    if override:
        path = Path(override)
        if path.is_dir():
            return path
    bundled = BASE_DIR / "cklib"
    if bundled.is_dir():
        return bundled
    sibling = BASE_DIR.parent.parent / "CK.Lib.Js"
    if sibling.is_dir():
        return sibling
    return None


class TaskCreateRequest(BaseModel):
    goal_id: str
    target_kernel: str
    title: str
    detail: str = ""
    priority: int = Field(default=1, ge=0, le=9)


def create_app(service: Any | None = None) -> FastAPI:
    board_service = service or build_live_board_service()

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        await board_service.startup()
        yield

    app = FastAPI(title="pgCK Goal Task Kernel Board MVP", lifespan=lifespan)
    # /assets is the canonical path; /static is kept for backward compatibility
    # with direct dev access. The localhost Envoy strips /static/ via prefix_rewrite,
    # so HTML templates reference /assets/ so the catch-all route forwards intact.
    app.mount("/assets", StaticFiles(directory=BASE_DIR / "static"), name="assets")
    app.mount("/static", StaticFiles(directory=BASE_DIR / "static"), name="static")
    cklib_dir = _resolve_cklib_dir()
    if cklib_dir is not None:
        app.mount("/cklib", StaticFiles(directory=cklib_dir), name="cklib")
    app.state.board_service = board_service
    app.state.cklib_dir = cklib_dir

    @app.get("/", response_class=HTMLResponse)
    async def root(request: Request) -> HTMLResponse:
        config = build_browser_config(request.url.hostname)
        return HTMLResponse(render_index(config))

    @app.get("/tasks.html", response_class=HTMLResponse)
    async def tasks_page(request: Request) -> HTMLResponse:
        config = build_browser_config(request.url.hostname)
        return HTMLResponse(render_tasks_page(config))

    @app.get("/healthz")
    async def healthz() -> dict[str, bool]:
        return {"ok": True}

    @app.get("/protocol")
    async def protocol(request: Request) -> dict[str, Any]:
        return protocol_document(request.url.hostname)

    @app.get("/api/board")
    async def api_board(request: Request) -> dict[str, Any]:
        return request.app.state.board_service.board_snapshot()

    @app.get("/api/goals")
    async def api_goals(request: Request) -> list[dict[str, Any]]:
        return request.app.state.board_service.list_goals()

    @app.get("/api/kernels")
    async def api_kernels(request: Request) -> list[dict[str, Any]]:
        return request.app.state.board_service.list_kernels()

    @app.post("/api/tasks", status_code=201)
    async def api_create_task(payload: TaskCreateRequest, request: Request) -> dict[str, Any]:
        try:
            return await request.app.state.board_service.create_task(payload.model_dump())
        except BoardValidationError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

    return app


app = create_app()

"""Companion download server for the Music Player app (iOS, or Android without on-device yt-dlp).

Endpoints (all require `Authorization: Bearer <MP_TOKEN>` except /health):
  GET  /health                     -> {status, yt_dlp}
  POST /jobs                       -> {id}                 body: {url, source, options}
  GET  /jobs/{id}                  -> status + progress (+ files, info when done)
  GET  /jobs/{id}/file?name=       -> the audio file
  POST /jobs/{id}/cancel           -> {ok}
  DELETE /jobs/{id}                -> {ok}   (the phone calls this after fetching the file)
  GET  /info?url=                  -> yt-dlp JSON for one item
  GET  /playlist?url=              -> flat playlist JSON
  GET  /search?q=&source=&count=   -> {entries: [...]}
  GET  /stream?url=                -> {url}  short-lived direct stream URL
  POST /update                     -> {status, version}    body: {channel}
  POST /fingerprint                -> {duration, fingerprint}   multipart file, needs fpcalc
"""

from __future__ import annotations

import asyncio
import hmac
import json
import os
import shutil
import subprocess
import tempfile
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from fastapi import Depends, FastAPI, File, Header, HTTPException, Query, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

from . import args as A
from .jobs import JobManager, Runner, real_runner


class JobRequest(BaseModel):
    url: str
    source: str | None = None
    options: dict[str, Any] = Field(default_factory=dict)


class UpdateRequest(BaseModel):
    channel: str = "stable"


def ytdlp_version() -> str | None:
    try:
        import yt_dlp.version as v

        return v.__version__
    except Exception:  # noqa: BLE001
        return None


def run_json(argv: list[str], timeout: int = 120) -> Any:
    """Runs yt-dlp as a subprocess and parses stdout as JSON (info/search/playlist)."""
    exe = [os.environ.get("MP_YTDLP", "yt-dlp")]
    try:
        r = subprocess.run(exe + argv, capture_output=True, text=True, timeout=timeout, check=False)
    except FileNotFoundError:
        import sys

        r = subprocess.run([sys.executable, "-m", "yt_dlp", *argv], capture_output=True, text=True, timeout=timeout, check=False)
    if r.returncode != 0 and not r.stdout.strip():
        raise HTTPException(status_code=502, detail=r.stderr.strip()[-600:] or "yt-dlp failed")
    try:
        return json.loads(r.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        raise HTTPException(status_code=502, detail="unexpected yt-dlp output") from None


def create_app(token: str | None = None, work_root: Path | None = None, runner: Runner = real_runner,
               cookies_file: str | None = None, allow_no_auth: bool | None = None) -> FastAPI:
    token = token if token is not None else os.environ.get("MP_TOKEN", "")
    if allow_no_auth is None:
        allow_no_auth = os.environ.get("MP_ALLOW_NO_AUTH") == "1"
    if not token and not allow_no_auth:
        raise RuntimeError("Set MP_TOKEN (recommended) or MP_ALLOW_NO_AUTH=1 for a trusted private network.")
    cookies_file = cookies_file or os.environ.get("MP_COOKIES") or None
    root = work_root or Path(os.environ.get("MP_WORKDIR", tempfile.gettempdir())) / "mp-jobs"
    manager = JobManager(root, runner=runner, workers=int(os.environ.get("MP_WORKERS", "2")),
                         ttl_seconds=int(os.environ.get("MP_TTL", "3600")), cookies_file=cookies_file)

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        async def loop() -> None:
            while True:
                await asyncio.sleep(300)
                manager.cleanup()

        task = asyncio.create_task(loop())
        yield
        task.cancel()

    app = FastAPI(title="Music Player server", version="0.1.0", lifespan=lifespan)
    app.state.manager = manager

    def auth(authorization: str | None = Header(default=None)) -> None:
        if not token:
            return
        supplied = (authorization or "").removeprefix("Bearer ").strip()
        if not hmac.compare_digest(supplied, token):
            raise HTTPException(status_code=401, detail="invalid token")

    @app.get("/health")
    def health() -> dict[str, Any]:
        return {"status": "ok", "yt_dlp": ytdlp_version(), "ffmpeg": shutil.which("ffmpeg") is not None,
                "fpcalc": shutil.which("fpcalc") is not None}

    @app.post("/jobs", status_code=202, dependencies=[Depends(auth)])
    def create_job(req: JobRequest) -> dict[str, str]:
        if not req.url.startswith(("http://", "https://")):
            raise HTTPException(status_code=400, detail="url must be http(s)")
        return {"id": manager.create(req.url, req.source, req.options).id}

    def _job(job_id: str):  # noqa: ANN202
        job = manager.get(job_id)
        if not job:
            raise HTTPException(status_code=404, detail="unknown job")
        return job

    @app.get("/jobs/{job_id}", dependencies=[Depends(auth)])
    def job_status(job_id: str) -> dict[str, Any]:
        return _job(job_id).to_json()

    @app.get("/jobs/{job_id}/file", dependencies=[Depends(auth)])
    def job_file(job_id: str, name: str | None = None) -> FileResponse:
        job = _job(job_id)
        files = job.files()
        if job.status != "done" or not files:
            raise HTTPException(status_code=409, detail="job is not finished")
        chosen = name or files[0]["name"]
        path = (job.work_dir / chosen).resolve()
        if job.work_dir.resolve() not in path.parents or not path.is_file():
            raise HTTPException(status_code=404, detail="no such file")
        return FileResponse(path, filename=path.name)

    @app.post("/jobs/{job_id}/cancel", dependencies=[Depends(auth)])
    def job_cancel(job_id: str) -> dict[str, bool]:
        _job(job_id)
        return {"ok": manager.cancel(job_id)}

    @app.delete("/jobs/{job_id}", dependencies=[Depends(auth)])
    def job_delete(job_id: str) -> dict[str, bool]:
        return {"ok": manager.delete(job_id)}

    @app.get("/info", dependencies=[Depends(auth)])
    def info(url: str) -> Any:
        return run_json(A.info_args(url, cookies_file))

    @app.get("/playlist", dependencies=[Depends(auth)])
    def playlist(url: str) -> Any:
        return run_json(A.playlist_args(url, cookies_file))

    @app.get("/search", dependencies=[Depends(auth)])
    def search(q: str, source: str = "youtube", count: int = Query(10, ge=1, le=50)) -> dict[str, Any]:
        prefix = A.SEARCH_PREFIX.get(source)
        if not prefix:
            raise HTTPException(status_code=400, detail=f"{source} has no search")
        data = run_json(A.search_args(prefix, q, count, cookies_file))
        return {"entries": data.get("entries", [])}

    @app.get("/stream", dependencies=[Depends(auth)])
    def stream(url: str) -> dict[str, str]:
        exe = os.environ.get("MP_YTDLP", "yt-dlp")
        r = subprocess.run([exe, *A.stream_args(url, cookies_file)], capture_output=True, text=True, timeout=120, check=False)
        line = next((ln for ln in r.stdout.splitlines() if ln.startswith("http")), "")
        if not line:
            raise HTTPException(status_code=502, detail=r.stderr.strip()[-600:] or "no stream url")
        return {"url": line}

    @app.post("/update", dependencies=[Depends(auth)])
    def update(req: UpdateRequest) -> dict[str, str | None]:
        exe = os.environ.get("MP_YTDLP", "yt-dlp")
        channel = {"stable": "stable", "nightly": "nightly", "master": "master"}.get(req.channel, "stable")
        r = subprocess.run([exe, "--update-to", channel], capture_output=True, text=True, timeout=300, check=False)
        return {"status": "DONE" if r.returncode == 0 else "FAILED", "version": ytdlp_version(), "output": r.stdout[-300:]}

    @app.post("/fingerprint", dependencies=[Depends(auth)])
    async def fingerprint(file: UploadFile = File(...)) -> dict[str, Any]:
        fpcalc = shutil.which("fpcalc")
        if not fpcalc:
            raise HTTPException(status_code=501, detail="fpcalc (chromaprint) is not installed")
        with tempfile.NamedTemporaryFile(delete=False, suffix=Path(file.filename or "a.bin").suffix) as tmp:
            tmp.write(await file.read())
        try:
            r = subprocess.run([fpcalc, "-json", tmp.name], capture_output=True, text=True, timeout=120, check=False)
        finally:
            os.unlink(tmp.name)
        if r.returncode != 0:
            raise HTTPException(status_code=422, detail=r.stderr.strip()[-300:])
        return json.loads(r.stdout)

    return app


def app_factory() -> FastAPI:  # for `uvicorn app.main:app_factory --factory`
    return create_app()


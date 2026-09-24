"""Download jobs: run yt-dlp in worker threads and expose progress."""

from __future__ import annotations

import json
import shutil
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

from . import args as A

Runner = Callable[[list[str], "Job"], dict[str, Any] | None]


class Cancelled(Exception):
    pass


@dataclass
class Job:
    id: str
    url: str
    source: str | None
    options: dict[str, Any]
    work_dir: Path
    status: str = "queued"  # queued | running | postprocessing | done | failed | cancelled
    progress: float = 0.0
    stage: str = "Queued"
    error: str | None = None
    info: dict[str, Any] | None = None
    created: float = field(default_factory=time.time)
    finished: float | None = None
    cancel_flag: threading.Event = field(default_factory=threading.Event)

    def files(self) -> list[dict[str, Any]]:
        if not self.work_dir.exists():
            return []
        out = []
        for p in sorted(self.work_dir.iterdir(), key=lambda x: x.stat().st_size, reverse=True):
            ext = p.suffix.lower().lstrip(".")
            if p.name.endswith(".info.json") or p.name.endswith(".part") or ext not in A.AUDIO_EXTENSIONS:
                continue
            out.append({"name": p.name, "size": p.stat().st_size})
        return out

    def to_json(self) -> dict[str, Any]:
        d: dict[str, Any] = {
            "id": self.id,
            "status": self.status,
            "progress": round(self.progress, 1),
            "stage": self.stage,
            "error": self.error,
        }
        if self.status == "done":
            d["files"] = self.files()
            d["info"] = self.info
        return d


def real_runner(argv: list[str], job: Job) -> dict[str, Any] | None:
    """Runs yt-dlp through its Python API using the exact CLI arguments."""
    import yt_dlp

    _, _, _, ydl_opts = yt_dlp.parse_options(argv)

    def hook(d: dict[str, Any]) -> None:
        if job.cancel_flag.is_set():
            raise Cancelled()
        if d.get("status") == "downloading":
            total = d.get("total_bytes") or d.get("total_bytes_estimate")
            if total:
                job.progress = d.get("downloaded_bytes", 0) * 100.0 / total
            job.status, job.stage = "running", "Downloading"
        elif d.get("status") == "finished":
            job.progress = 100.0

    def pp_hook(d: dict[str, Any]) -> None:
        if job.cancel_flag.is_set():
            raise Cancelled()
        if d.get("status") == "started":
            job.status = "postprocessing"
            job.stage = {"ExtractAudio": "Converting audio", "Metadata": "Embedding metadata",
                         "EmbedThumbnail": "Embedding cover", "SponsorBlock": "Removing non-music parts"}.get(
                d.get("postprocessor", ""), "Processing")

    ydl_opts["progress_hooks"] = [hook]
    ydl_opts["postprocessor_hooks"] = [pp_hook]
    ydl_opts["quiet"] = True
    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        return ydl.extract_info(argv[-1], download=True)


class JobManager:
    def __init__(self, root: Path, runner: Runner = real_runner, workers: int = 2, ttl_seconds: int = 3600,
                 cookies_file: str | None = None) -> None:
        self.root = root
        self.root.mkdir(parents=True, exist_ok=True)
        self.runner = runner
        self.pool = ThreadPoolExecutor(max_workers=workers)
        self.jobs: dict[str, Job] = {}
        self.ttl = ttl_seconds
        self.cookies_file = cookies_file
        self._lock = threading.Lock()

    def create(self, url: str, source: str | None, options: dict[str, Any]) -> Job:
        job_id = uuid.uuid4().hex[:12]
        job = Job(id=job_id, url=url, source=source, options=options, work_dir=self.root / job_id)
        job.work_dir.mkdir(parents=True, exist_ok=True)
        with self._lock:
            self.jobs[job_id] = job
        self.pool.submit(self._run, job)
        return job

    def get(self, job_id: str) -> Job | None:
        return self.jobs.get(job_id)

    def _run(self, job: Job) -> None:
        if job.cancel_flag.is_set():
            job.status, job.stage = "cancelled", "Cancelled"
            return
        job.status, job.stage = "running", "Starting"
        try:
            argv = A.download_args(job.url, str(job.work_dir), job.options, job.source, self.cookies_file)
            info = self.runner(argv, job)
            for p in job.work_dir.glob("*.info.json"):
                try:
                    job.info = json.loads(p.read_text(encoding="utf-8"))
                    break
                except (OSError, ValueError):
                    continue
            if job.info is None and isinstance(info, dict):
                job.info = {k: v for k, v in info.items() if isinstance(v, (str, int, float, bool, list, dict, type(None)))
                            and k not in ("formats", "requested_formats", "thumbnails", "automatic_captions", "subtitles")}
            if not job.files():
                raise RuntimeError("yt-dlp produced no audio file")
            job.status, job.stage, job.progress = "done", "Done", 100.0
        except Cancelled:
            job.status, job.stage = "cancelled", "Cancelled"
        except Exception as e:  # noqa: BLE001 - reported to the client
            job.status, job.stage, job.error = "failed", "Failed", str(e)
        finally:
            job.finished = time.time()

    def cancel(self, job_id: str) -> bool:
        job = self.get(job_id)
        if not job:
            return False
        job.cancel_flag.set()
        if job.status == "queued":
            job.status, job.stage = "cancelled", "Cancelled"
        return True

    def delete(self, job_id: str) -> bool:
        with self._lock:
            job = self.jobs.pop(job_id, None)
        if not job:
            return False
        job.cancel_flag.set()
        shutil.rmtree(job.work_dir, ignore_errors=True)
        return True

    def cleanup(self, now: float | None = None) -> int:
        """Delete finished jobs older than the TTL (the phone normally deletes its own)."""
        now = now or time.time()
        stale = [j.id for j in self.jobs.values() if j.finished and now - j.finished > self.ttl]
        for job_id in stale:
            self.delete(job_id)
        return len(stale)

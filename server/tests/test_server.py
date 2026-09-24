import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app import args as A
from app.main import create_app

TOKEN = "s3cret"
AUTH = {"Authorization": f"Bearer {TOKEN}"}


def fake_runner_ok(argv, job):
    """Pretends to be yt-dlp: writes an audio file + info json into the -P directory."""
    out = Path(argv[argv.index("-P") + 1])
    (out / "abc123.m4a").write_bytes(b"\x00" * 2048)
    (out / "abc123.info.json").write_text('{"id": "abc123", "title": "Song", "uploader": "Chan"}', encoding="utf-8")
    job.progress = 50.0
    return {"id": "abc123"}


def fake_runner_fail(argv, job):
    raise RuntimeError("ERROR: Video unavailable")


@pytest.fixture()
def client(tmp_path):
    return TestClient(create_app(token=TOKEN, work_root=tmp_path, runner=fake_runner_ok))


def wait_for(client, job_id, statuses=("done", "failed", "cancelled")):
    for _ in range(200):
        j = client.get(f"/jobs/{job_id}", headers=AUTH).json()
        if j["status"] in statuses:
            return j
        time.sleep(0.02)
    raise AssertionError("job did not finish")


def test_refuses_to_start_without_a_token(tmp_path):
    with pytest.raises(RuntimeError):
        create_app(token="", work_root=tmp_path, allow_no_auth=False)
    create_app(token="", work_root=tmp_path, allow_no_auth=True)


def test_health_is_public_everything_else_needs_the_token(client):
    assert client.get("/health").json()["status"] == "ok"
    assert client.post("/jobs", json={"url": "https://youtu.be/x"}).status_code == 401
    assert client.get("/info", params={"url": "x"}, headers={"Authorization": "Bearer nope"}).status_code == 401


def test_job_lifecycle_download_and_cleanup(client):
    r = client.post("/jobs", json={"url": "https://youtu.be/abc123", "source": "youtube", "options": {"format": "m4a"}}, headers=AUTH)
    assert r.status_code == 202
    job_id = r.json()["id"]
    done = wait_for(client, job_id)
    assert done["status"] == "done"
    assert done["files"][0]["name"] == "abc123.m4a"
    assert done["info"]["title"] == "Song"
    f = client.get(f"/jobs/{job_id}/file", headers=AUTH)
    assert f.status_code == 200 and len(f.content) == 2048
    assert client.delete(f"/jobs/{job_id}", headers=AUTH).json() == {"ok": True}
    assert client.get(f"/jobs/{job_id}", headers=AUTH).status_code == 404


def test_file_is_only_served_when_finished_and_never_outside_the_job_dir(client):
    job_id = client.post("/jobs", json={"url": "https://youtu.be/abc123"}, headers=AUTH).json()["id"]
    wait_for(client, job_id)
    assert client.get(f"/jobs/{job_id}/file", params={"name": "../../etc/passwd"}, headers=AUTH).status_code == 404


def test_failures_are_reported(tmp_path):
    c = TestClient(create_app(token=TOKEN, work_root=tmp_path, runner=fake_runner_fail))
    job_id = c.post("/jobs", json={"url": "https://youtu.be/x"}, headers=AUTH).json()["id"]
    j = wait_for(c, job_id)
    assert j["status"] == "failed"
    assert "Video unavailable" in j["error"]


def test_rejects_non_http_urls(client):
    assert client.post("/jobs", json={"url": "file:///etc/passwd"}, headers=AUTH).status_code == 400


def test_cancel_and_unknown_job(client):
    assert client.post("/jobs/nope/cancel", headers=AUTH).status_code == 404
    assert client.get("/jobs/nope", headers=AUTH).status_code == 404


def test_search_only_for_sources_with_a_search_prefix(client):
    assert client.get("/search", params={"q": "x", "source": "bandcamp"}, headers=AUTH).status_code == 400


def test_stale_finished_jobs_are_cleaned_up(tmp_path):
    app = create_app(token=TOKEN, work_root=tmp_path, runner=fake_runner_ok)
    c = TestClient(app)
    job_id = c.post("/jobs", json={"url": "https://youtu.be/abc123"}, headers=AUTH).json()["id"]
    wait_for(c, job_id)
    mgr = app.state.manager
    assert mgr.cleanup(now=time.time() + 10) == 0
    assert mgr.cleanup(now=time.time() + 4000) == 1
    assert not (tmp_path / job_id).exists()


# --- argument builder: must stay identical to lib/features/downloader/ytdlp_args.dart ----------


def pair(a, flag, value):
    i = a.index(flag)
    return a[i + 1] == value


def test_download_args_defaults():
    a = A.download_args("https://youtu.be/x", "/tmp/j", {}, "youtube")
    assert pair(a, "-f", "bestaudio/best") and "-x" in a and "--embed-metadata" in a
    assert pair(a, "--audio-format", "m4a") and pair(a, "--audio-quality", "0")
    assert pair(a, "--parse-metadata", "title:%(artist)s - %(title)s")
    assert pair(a, "--sponsorblock-remove", "music_offtopic")
    assert pair(a, "-P", "/tmp/j") and pair(a, "-o", "%(id)s.%(ext)s")
    assert a[-1] == "https://youtu.be/x"


def test_download_args_variants():
    orig = A.download_args("u", "/d", {"format": "original"}, "soundcloud")
    assert "--audio-format" not in orig and "--sponsorblock-remove" not in orig
    flac = A.download_args("u", "/d", {"format": "flac", "parseTitle": False}, None)
    assert pair(flac, "--audio-format", "flac") and "--audio-quality" not in flac
    assert "--embed-thumbnail" not in flac and "--parse-metadata" not in flac
    thumb = A.download_args("u", "/d", {"embedThumbnail": True}, None)
    assert "--embed-thumbnail" in thumb and pair(thumb, "--convert-thumbnails", "jpg")
    extra = A.download_args("u", "/d", {"limitRate": "2M", "extraArgs": ["--geo-bypass"]}, None, "/c.txt")
    assert pair(extra, "--limit-rate", "2M") and pair(extra, "--cookies", "/c.txt") and "--geo-bypass" in extra


def test_other_command_lines():
    assert A.search_args("ytsearch", "daft punk", 10)[-1] == "ytsearch10:daft punk"
    assert "-g" in A.stream_args("u") and "--flat-playlist" in A.playlist_args("u")

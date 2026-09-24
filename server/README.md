# Companion server

A small FastAPI service that runs **yt-dlp + ffmpeg** on a machine you control (home PC, Raspberry Pi,
VPS) so the phone only has to fetch the finished file. It is required for iOS and optional on
Android, where the app can run yt-dlp on the device.

## Run it

```bash
cd server
echo "MP_TOKEN=$(openssl rand -hex 24)" > .env
docker compose up -d --build
curl http://localhost:8000/health
```

Without Docker: `pip install -r requirements.txt && MP_TOKEN=... uvicorn app.main:app_factory --factory --port 8000`
(needs `ffmpeg`, and `fpcalc` for fingerprinting, on the PATH).

In the app: **Settings → Downloads → Downloader engine → Companion server**, enter
`http://<host>:8000` and the token.

## Security

* Every endpoint except `/health` needs `Authorization: Bearer <MP_TOKEN>`. The server refuses to start
  without a token unless you set `MP_ALLOW_NO_AUTH=1` (only for a network you fully trust).
* **Do not expose it to the public internet.** Put it behind **Tailscale** (recommended: bind to the
  Tailscale address) or a reverse proxy with TLS.
* Finished files are deleted when the phone calls `DELETE /jobs/{id}`; anything older than `MP_TTL`
  seconds (default 3600) is removed automatically.

## API

| Method | Path | Notes |
|---|---|---|
| GET | `/health` | `{status, yt_dlp, ffmpeg, fpcalc}` (public) |
| POST | `/jobs` | `{url, source?, options?}` → `{id}` (202) |
| GET | `/jobs/{id}` | `{status, progress, stage, error, files, info}`; status is queued / running / postprocessing / done / failed / cancelled |
| GET | `/jobs/{id}/file?name=` | the audio file (only when done) |
| POST | `/jobs/{id}/cancel` | |
| DELETE | `/jobs/{id}` | cleanup |
| GET | `/info?url=` · `/playlist?url=` | yt-dlp JSON |
| GET | `/search?q=&source=youtube\|soundcloud&count=` | `{entries}` |
| GET | `/stream?url=` | `{url}` short-lived stream URL |
| POST | `/update` | `{channel: stable\|nightly\|master}` – updates yt-dlp |
| POST | `/fingerprint` | multipart audio → `fpcalc -json` |

`options` mirrors the app: `format` (`original|m4a|opus|mp3|flac`), `quality`, `sponsorBlock`,
`parseTitle`, `embedThumbnail`, `limitRate`, `extraArgs`. The command lines are built by `app/args.py`,
which must stay identical to `lib/features/downloader/ytdlp_args.dart`.

## Tests

```bash
pip install -r requirements-dev.txt
pytest
```

Keep yt-dlp current: `docker compose build --no-cache` or call `POST /update` weekly.

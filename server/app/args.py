"""yt-dlp command lines. Kept in lock-step with lib/features/downloader/ytdlp_args.dart
(the Flutter app builds the same arguments for its on-device engine)."""

from __future__ import annotations

from typing import Any

YOUTUBE_SOURCES = {"youtube", "youtubeMusic"}
SEARCH_PREFIX = {"youtube": "ytsearch", "youtubeMusic": "ytsearch", "soundcloud": "scsearch"}
AUDIO_EXTENSIONS = {"m4a", "mp3", "opus", "ogg", "oga", "flac", "wav", "aac", "webm", "mka", "wma", "mp4", "weba"}


def audio_format_args(options: dict[str, Any]) -> list[str]:
    fmt = options.get("format", "m4a")
    quality = str(options.get("quality", 0))
    if fmt == "original":
        return []
    if fmt in ("m4a", "opus", "mp3"):
        return ["--audio-format", fmt, "--audio-quality", quality]
    if fmt == "flac":
        return ["--audio-format", "flac"]
    return []


def download_args(url: str, work_dir: str, options: dict[str, Any], source: str | None = None,
                  cookies_file: str | None = None) -> list[str]:
    a: list[str] = [
        "--no-playlist",
        "-f", "bestaudio/best",
        "-x",
        *audio_format_args(options),
        "--embed-metadata",
    ]
    if options.get("embedThumbnail", False):
        a += ["--embed-thumbnail", "--convert-thumbnails", "jpg"]
    if options.get("parseTitle", True):
        a += ["--parse-metadata", "title:%(artist)s - %(title)s"]
    a += [
        "--write-info-json",
        "--no-mtime",
        "--newline",
        "--progress",
        "--retries", "5",
        "--fragment-retries", "5",
        "--concurrent-fragments", "4",
    ]
    if options.get("limitRate"):
        a += ["--limit-rate", str(options["limitRate"])]
    if options.get("sponsorBlock", True) and source in YOUTUBE_SOURCES:
        a += ["--sponsorblock-remove", "music_offtopic"]
    if cookies_file:
        a += ["--cookies", cookies_file]
    a += [str(x) for x in options.get("extraArgs", []) if x]
    a += ["-P", work_dir, "-o", "%(id)s.%(ext)s", url]
    return a


def info_args(url: str, cookies_file: str | None = None) -> list[str]:
    a = ["-J", "--no-playlist", "--no-warnings", "--skip-download"]
    if cookies_file:
        a += ["--cookies", cookies_file]
    return [*a, url]


def playlist_args(url: str, cookies_file: str | None = None) -> list[str]:
    a = ["-J", "--flat-playlist", "--no-warnings"]
    if cookies_file:
        a += ["--cookies", cookies_file]
    return [*a, url]


def search_args(prefix: str, query: str, count: int, cookies_file: str | None = None) -> list[str]:
    a = ["-J", "--flat-playlist", "--no-warnings"]
    if cookies_file:
        a += ["--cookies", cookies_file]
    return [*a, f"{prefix}{count}:{query}"]


def stream_args(url: str, cookies_file: str | None = None) -> list[str]:
    a = ["-f", "bestaudio/best", "-g", "--no-playlist", "--no-warnings"]
    if cookies_file:
        a += ["--cookies", cookies_file]
    return [*a, url]

#!/usr/bin/env bash
# Downloads a small, freely licensed test item with the given site's extractor.
set -euo pipefail
case "${1:-archive}" in
  archive)    url="https://archive.org/details/testmp3testfile" ;;                 # public domain test file
  youtube)    url="https://www.youtube.com/watch?v=aqz-KE-bpKQ" ;;                 # Big Buck Bunny, CC BY 3.0 (Blender Foundation)
  soundcloud) url="https://soundcloud.com/wearecc/sets/creative-commons" ;;        # placeholder CC set - adjust if it disappears
  *) echo "unknown site"; exit 2 ;;
esac
out="$(mktemp -d)"
yt-dlp --no-playlist --playlist-items 1 -x --audio-format m4a --max-filesize 30M -P "$out" -o "%(id)s.%(ext)s" "$url"
ls -la "$out"
test -n "$(find "$out" -name '*.m4a' -size +10k)"
echo "canary ok: $1"

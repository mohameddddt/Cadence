#!/usr/bin/env bash
# Exercises android/.../TagIO.java (the jaudiotagger wrapper) on a plain JVM against real MP3,
# FLAC, M4A and OGG files: write MusicBrainz + custom fields + artwork, read them back.
# Needs: java 17, ffmpeg, curl.
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
jar="$work/jaudiotagger.jar"
curl -sfL -o "$jar" https://repo1.maven.org/maven2/net/jthink/jaudiotagger/3.0.1/jaudiotagger-3.0.1.jar
for spec in mp3:libmp3lame flac:flac m4a:aac ogg:libvorbis opus:libopus wav:pcm_s16le; do
  ffmpeg -y -loglevel error -f lavfi -i "sine=frequency=440:duration=3" -c:a "${spec#*:}" "$work/t.${spec%%:*}"
done
ffmpeg -y -loglevel error -f lavfi -i "color=c=red:s=300x300:d=1" -frames:v 1 "$work/art.jpg"
mkdir -p "$work/classes"
sep=":"; conv() { echo "$1"; }
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) sep=";"; conv() { cygpath -m "$1"; } ;; esac
jar_p="$(conv "$jar")"; classes_p="$(conv "$work/classes")"; work_p="$(conv "$work")"
javac -cp "$jar_p" -d "$classes_p" android/app/src/main/java/dev/personal/musicplayer/TagIO.java tool/jvm/TagRoundTrip.java
java -cp "$jar_p$sep$classes_p" TagRoundTrip "$work_p"

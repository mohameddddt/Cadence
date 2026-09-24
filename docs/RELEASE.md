# Building & releasing

## 1. Signing (do this once, back it up)

```bash
keytool -genkey -v -keystore ~/musicplayer-release.jks -keyalg RSA -keysize 4096 -validity 10000 -alias musicplayer
```

**Back the keystore up (password manager + offline copy).** If you lose it you can never ship an update over an existing install.

Local builds read `android/key.properties` (git-ignored):

```properties
storeFile=/home/you/musicplayer-release.jks
storePassword=…
keyAlias=musicplayer
keyPassword=…
```

Without it, `flutter build apk --release` falls back to the debug key so that local smoke tests work.
CI refuses to publish without the keystore.

## 2. Build

```bash
flutter build apk --release --split-per-abi     # arm64-v8a, armeabi-v7a, x86_64 (yt-dlp+ffmpeg are the big part)
```

R8 shrinking is enabled with keep rules in `android/app/proguard-rules.pro` (youtubedl-android, jaudiotagger and the
plugins). If you add a reflective library, test the *release* build, not only debug: shrinking has already broken yt-dlp
twice, only at runtime - commons-compress classes were merged away (keep rules in `proguard-rules.pro`), and the resource
shrinker replaced the bundled yt-dlp (`res/raw/ytdlp`) with a stub (`android/app/src/main/res/raw/keep.xml`).
Minimum smoke test on the release APK: share a YouTube/SoundCloud link into the app and let the download finish.

## 3. Publish on GitHub

1. Update `version:` in `pubspec.yaml`, `AppVersion` in `lib/ui/screens/settings_screen.dart` and `CHANGELOG.md` (`## [x.y.z]`).
2. Add the repository secrets: `MUSICPLAYER_KEYSTORE_B64` (`base64 -w0 musicplayer-release.jks`), `MUSICPLAYER_KEYSTORE_PASSWORD`,
   `MUSICPLAYER_KEY_ALIAS`, `MUSICPLAYER_KEY_PASSWORD`.
3. `git tag v0.1.0 && git push --tags` – the *Release* workflow builds the split APKs and attaches them with the changelog section.

[Obtainium](https://github.com/ImranR98/Obtainium) users can track the GitHub releases directly. F-Droid needs reproducible builds and will label
the app with the *NonFreeNet* anti-feature because of the YouTube functionality.

## 4. Other notes

* **Never publish to Google Play** – downloading from YouTube violates its terms and Play removes such apps.
* Crash reporting: none is bundled. ACRA (self-hosted) is the privacy-friendly option if you want it.
* iOS: build on a Mac with the companion server and sideload (AltStore/SideStore, or TestFlight for personal use).
* Manual test matrix before a release: Android 8, 10, 13, 14, 15; a low-RAM device; Bluetooth, car head unit, wired headphones.

# Building the PegLeg Android APK (dev branch)

PegLeg's `dev` branch targets **Godot 4.7 (.NET / Mono)** and ships an
**"Android (Test)"** export preset that produces a release APK for arm64.

Package: `com.tomatech.pegleg` · Label: `PegLeg Beta` · Version `0.3.64` (code `3064`)

## Option A — GitHub Actions (recommended, no local setup)

1. Make sure `.github/workflows/android.yml` exists on your branch.
   (It builds with Godot 4.7 Mono, JDK 17, .NET 10 SDK and Android SDK
   platform/build-tools 35 + NDK r28.)
2. Push to the branch (or run the workflow manually via **Actions →
   Android APK (Beta) → Run workflow**).
3. When it finishes, download the APK from any of:
   - the **android-beta** pre-release on the Releases page, or
   - the **PegLegBeta-Android** workflow artifact, or
   - the `apk/ci-<run number>` branch (APK split into <100MB chunks +
     `sha256.txt` / `build-info.txt`):
     `cat PegLegBeta-Android.apk.part.* > PegLegBeta-Android.apk`
     then `sha256sum -c sha256.txt`.

The CI build is a **release** build signed with the standard Android debug
key (`androiddebugkey`), so beta APKs keep a stable signature and can be
updated by sideloading over the previous install. For a Play Store release,
generate a real keystore and point the `export/android/release_keystore*`
editor settings at it.

## Option B — Local build

Requirements:

| Tool | Version |
| ---- | ------- |
| Godot editor (Mono/.NET) | 4.7-stable (must match `Godot.NET.Sdk/4.7.0` in `PegLegGD.csproj`) |
| Godot export templates (Mono) | 4.7-stable |
| .NET SDK | 10.0.x |
| JDK | 17 (Temurin recommended — Gradle rejects newer JDKs) |
| Android SDK | cmdline-tools + `platform-tools`, `build-tools;35.0.0`, `platforms;android-35`, `cmake;3.10.2.4988404`, `ndk;28.1.13356709` |

Steps:

1. Install the export templates (`Editor → Manage Export Templates →
   Install from File`, or unzip the `.tpz` into
   `~/.local/share/godot/export_templates/4.7.stable/`).
2. Accept the Android SDK licenses: `yes | sdkmanager --licenses`.
3. Create a debug keystore (or your own release keystore):
   `keytool -genkeypair -keystore ~/.android/debug.keystore -storepass android -alias androiddebugkey -keypass android -keyalg RSA -keysize 2048 -validity 10950 -dname "CN=Android Debug,O=Android,C=US"`
4. In Godot: **Editor → Editor Settings → Export → Android**, set the
   Android SDK path, JDK path, and debug/release keystores.
5. Open the project, let it import, then **Project → Export… →
   "Android (Test)" → Export Project**.

Headless equivalent after steps 1–4:

```sh
godot --headless --path . --import
godot --headless --path . --export-release "Android (Test)" "Builds/Android/Beta/PegLegBeta-Android.apk"
```

## Installing on your phone

1. Copy `PegLegBeta-Android.apk` to your (arm64, Android 7+) phone.
2. Open it and allow **Install unknown apps** when prompted.
3. Play Protect may warn that the app is from an unknown developer —
   that is expected for a sideloaded beta.

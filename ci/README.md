# Building the PegLeg Android APK

PegLeg is a **Godot 4.7 .NET (C#)** project. Building the Android APK therefore needs the
Godot *.NET* editor plus the matching *.NET* export templates, a JDK, the .NET SDK and the
Android SDK/NDK/Gradle stack — roughly 6 GB of tooling that is downloaded on demand rather
than stored in the repository.

Everything is driven by one script: [`ci/build-android-apk.sh`](build-android-apk.sh).

```bash
# on a machine with JDK 17 + .NET SDK 10 + git + curl + unzip:
./ci/build-android-apk.sh
# -> Builds/Android/Beta/PegLegBeta-Android.apk  (+ build-report.md)
```

Useful environment variables:

| Variable | Default | Meaning |
| --- | --- | --- |
| `GODOT_TAG` | `4.7.2-stable` | Godot release used for the editor **and** the templates |
| `GODOT_PRESET` | `Android (Test)` | Export preset from `export_presets.cfg` |
| `EXPORT_MODE` | `release` | `release` (optimised) or `debug` |
| `OUTPUT_APK` | `Builds/Android/Beta/PegLegBeta-Android.apk` | Output path |
| `TARGET_SDK` / `TARGET_BUILD_TOOLS` / `TARGET_NDK` | `36` / `36.1.0` / `29.0.14206865` | Versions required by Godot 4.7's Gradle build |

## Running it in CI

`.github/workflows/android-apk.yml` (copy [`ci/android-apk.yml`](android-apk.yml) to that path)
is a thin wrapper: it installs JDK 17 + .NET, then runs the script. It triggers on pushes to
the `arena/**` and `dev` branches and can also be started manually from the Actions tab.

The APK is uploaded as a workflow artifact and, when the workflow has `contents: write`,
attached to a release tagged `android-<branch>` so it can be downloaded straight to a phone.

## What the script does

1. Checks `JAVA_HOME` / `dotnet` and resolves the Android SDK (downloading the command line
   tools if needed), then installs platform 36, build-tools 36.1.0 and NDK 29.
2. Downloads the Godot *.NET* editor and extracts only the Android parts of the *.NET* export
   templates (~1.4 GB instead of 4 GB).
3. Installs the Gradle build template into `res://android/build` (what the editor's
   *Project → Install Android Build Template* menu item does interactively) and writes the
   `.build_version` marker Godot verifies, `4.7.2.stable.mono`.
4. Creates a throwaway signing keystore and exposes it to Godot through the
   `GODOT_ANDROID_KEYSTORE_{DEBUG,RELEASE}_*` environment variables.
5. Compiles the C# project for the android platform (fast feedback on C# errors).
6. Imports the project resources and exports the preset. If the export fails it retries with
   the `linux-bionic` runtime identifier and finally as a debug build.
7. Verifies the APK (`apksigner`, `aapt2`, library list, SHA-256) and writes `build-report.md`.

## Notes

* The Gradle build template lands in `android/`, which is `.gitignore`d — it is generated,
  never committed.
* Set `GH_TOKEN` and `GITHUB_REPOSITORY` to have the script publish/update the
  `android-<branch>` release with the APK.
* Godot 4.7 marks C#/.NET Android export as *experimental*; the Gradle build path is the
  supported one for `net10.0` projects (template exports would need `net9.0`).

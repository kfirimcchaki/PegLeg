# Android boot-freeze fixes (Galaxy A17 and others)

The v0.3.64 Android APK could freeze on its loading screen on phones (confirmed on
Samsung Galaxy A17). Root causes found by tracing the boot sequence
(`Bootstrap` → `PegLegResourceManager.FetchAndLoadPackages` → …):

## 1. The 326MB resource pack could never finish downloading on a phone (the freeze)

- On first launch the app downloads `PegLegResources-m-v4.0.0.pck` (**326MB**).
- All downloads went through the shared `HttpClient` with `Timeout = 60 seconds`,
  and `HttpClient.Timeout` covers the **entire content download**, not just the
  connection. 326MB in 60s needs ~45Mbps sustained — fine on desktop fiber,
  impossible on most phone connections.
- At 60s a `TaskCanceledException` was thrown inside `async void Initialise()`
  with no `try/catch`, so the boot sequence died silently and the app sat on
  the loading screen forever.
- Worse, the partial file was written directly to the final path, so the next
  launch saw "pack exists", skipped the download, and ran broken.

Fixes (`Scripts/EndpointRequests/WebHelpers.cs`,
`Scripts/PegLegResourceManager.cs`, `Scenes/GithubHelper.cs`):

- New timeout-free `DownloadClient` used by all large downloads (with only a
  60-minute dead-connection cap).
- Downloads go to a `.tmp` file, are size-verified against the release asset
  (`ReleaseAsset.size`), then atomically renamed.
- Any download failure now falls back to local/bundled resources instead of
  killing the boot — the app always starts.
- Cached packs are size-verified on boot; corrupt partials left by older
  versions are deleted and re-downloaded (self-healing, no manual Clear Data
  needed — though it doesn't hurt).

## 2. Boot preloaded EVERY item texture into RAM (minutes-long stall / OOM)

`PreloadTemplateTextures` queued Preview+Icon+PackImage+LoadingScreen loads for
every item template (thousands of textures, 1000-way concurrency, permanently
cached). Fine on a 16GB desktop; on a 4–6GB phone it stalls boot for minutes
and risks an out-of-memory kill.

Fix: the preload is skipped on mobile — textures load lazily on demand
(`Scripts/PegLegResourceManager.cs`).

## 3. Desktop-only window manipulation ran on Android

`Bootstrap` forced `Transparent = true`, window size/position, screen selection
and `DisplayServer.SetIcon` on every platform. On mobile the OS owns the
window, and forcing transparency (explicitly disabled for mobile in
`project.godot`) risks a broken/black render surface.

Fix: all window chrome/positioning is now skipped on mobile
(`Scripts/Bootstrap.cs`).

## 4. Offline detection always reported "Offline" on Android

`WebHelpers.Ping` uses ICMP, which needs raw-socket privileges Android apps
don't have, so every login failure looked like "no internet".

Fix: on mobile, connectivity is probed with a fast TCP connect to DNS
(`8.8.8.8:53`, `1.1.1.1:53` fallback).

## 5. Android 15 (Galaxy A17) packaging/perf tuning

- `screen/edge_to_edge=true` in the Android export preset (enforced for
  API 35-targeting apps on Android 15/One UI 7).
- `run/max_fps.mobile=60` — the 144fps desktop cap is pointless on a 90Hz
  phone and just burns battery/CPU on a budget SoC like the Exynos 1330.

## Samsung Galaxy A17 notes

- First launch still downloads the 326MB resource pack — use WiFi; progress is
  shown; if it fails you still get a working app with bundled data and it
  retries next launch.
- arm64 only (Exynos 1330 ✓), Android 7+ (A17 ships Android 15 ✓).
- After installing the fixed APK over the frozen one, just launch it — the
  self-healing cache check cleans up any corrupt pack from the old version.

## Getting a fixed build

See `docs/ANDROID_BUILD.md`: push a branch containing these fixes and run the
`Android APK (Beta)` workflow, or build locally with Godot 4.7 Mono + JDK 17 +
.NET 10 SDK + Android SDK 35.

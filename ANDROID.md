# PegLeg on Android

PegLeg already ships a portrait phone interface (`Scenes/Mobile/mobileInterface.tscn`), but the
Android build was never wired into the parts of the engine that are specific to phones: the back
button, display cutouts/gesture areas and touch-only interaction. This document lists what the
Android build of this branch changes, and how to produce the APK.

## Building the APK

```bash
./ci/build-android-apk.sh          # -> Builds/Android/Beta/PegLegBeta-Android.apk
```

See [ci/README.md](ci/README.md) for requirements and environment variables, or copy
[`ci/android-apk.yml`](ci/android-apk.yml) to `.github/workflows/android-apk.yml` to build it on
GitHub Actions (`arena/**` and `dev` pushes, plus a manual *Run workflow* button).

The APK is arm64-v8a only, signed with a build keystore, and installs as `com.tomatech.pepleg`
(same package name as the official beta, so it replaces an existing install — the signing key has
to match for Android to accept the update).

## What is adapted to Android

### Back button and back gesture

`application/config/quit_on_go_back` stays `false`, so Godot never exits on its own; instead
`Scripts/TargetResolutionSetter.cs` subscribes to `Window.GoBackRequested` (which Godot emits on
the root window for the Android back button/gesture) and resolves it the way a native app does:

| State | Back does |
| --- | --- |
| An overlay is open | The overlay closes (via `Scripts/Overlays/ModalWindow.cs`, which only reacts for user-closable top windows, so modal prompts stay modal) |
| A context menu is open | The menu is dismissed (`ContextMenu.CloseOpenMenu()`) |
| Another window (dialog) is visible | Nothing is closed, the app stays where it is |
| A tab other than the first selectable one is open | The main tab bar returns to the first tab (`VirtualTabBar.GoBackToFirstTab()`) |
| Already on the first tab, nothing open | The app exits |

### Display cutouts and gesture areas

`Scripts/TargetResolutionSetter.cs` pads the interface's `Content` container with the insets
reported by `DisplayServer.GetDisplaySafeArea()` (converted from screen pixels to the
`canvas_items` stretch units the project uses), so the top bar and the tab bar never end up under a
notch, a camera hole or the gesture indicator. The padding is re-applied when the window size
changes and when the app is resumed (insets can change while it is in the background), and it can
be disabled per scene with the `adaptToMobileSafeArea` export. Devices that report no insets are
left untouched.

### Touch-only interaction

* **Long press menus** — `ContextMenuHook` already implemented a 1 second hold for touch, and
  `ContextMenu` already had `OS.HasFeature("mobile")` branches, but the menu itself was only
  instanced in the desktop scenes, so a long press did nothing on a phone. The mobile interfaces now
  instance it under `NonUI` exactly like the desktop ones, which makes long press menus (inspect,
  recycle, pin quest, copy id, …) work on Android. Component loading is now fault tolerant so one
  broken menu entry cannot take the interface down.
* Buttons, tab bars and scrolling use the existing touch paths (`ResponsiveButton` already swaps its
  shader outline for the fallback progress bar on mobile, `ScrollContainer` handles finger drags).

### Build and runtime settings

| Setting | Value | Reason |
| --- | --- | --- |
| `display/window/handheld/orientation` | `5` (sensor portrait) | the app is portrait only; the mobile scenes also call `ScreenSetOrientation(SensorPortrait)` at runtime |
| `run/max_fps.mobile` | `60` | the desktop default is 144, which is wasted heat and battery on a phone |
| `dotnet/include_debug_symbols` (Android preset) | `false` | smaller release APK |
| `viewport/transparent_background.mobile` | `false` | desktop only effect, avoids a needless transparent surface on Android |

## Not changed

* The update checker already handles Android: it picks the `.apk` asset of the latest release and
  opens it in the browser (`Scripts/UserInterface/Settings/UpdateChecker.cs`), leaving the actual
  install to Android's package installer.
* Themes, login, accounts and all companion features are platform independent and work unchanged.

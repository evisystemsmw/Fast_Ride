# Picture-in-Picture (PiP) — Fast Ride Driver

## Overview

The driver navigation screen supports Android Picture-in-Picture mode. When active, the app shrinks into a small floating window so the driver can see the live map while using other apps or while the phone screen is otherwise occupied.

---

## How It Works

### Entry Points

| Trigger | Behaviour |
|---|---|
| Driver taps the floating PiP button (top-right, below the nav bar) | Enters PiP immediately |
| Driver presses the Android Home button while a trip is active | Enters PiP automatically (via `onUserLeaveHint`) |
| `Start Trip` button is tapped | Calls `_setPip(true)` — auto-enters PiP on next Home press |

### Exit

Tap the PiP window to expand it back to full screen. Android handles this natively.

---

## Architecture

### Flutter Side

**Channels** (both declared as `static const` in `_DriverNavigationScreenState`):

```
MethodChannel  →  com.fastrider.app/pip
EventChannel   →  com.fastrider.app/pip_events
```

**`_setPip(bool enabled)`**
Calls `enablePip` or `disablePip` on the method channel. This sets a flag on the native side that controls whether `onUserLeaveHint` triggers PiP.

**`_listenPipMode()`**
Subscribes to the event channel. Every time Android fires `onPictureInPictureModeChanged`, the native side pushes `true`/`false` to the stream. Flutter updates `_inPipMode` and calls `widget.onPipChanged`.

**`_inPipMode` state effects**
- All overlay UI (banners, cards, strips) is hidden — only the `GoogleMap` is shown
- Camera zoom increases to `18.5`, tilt drops to `0` for a clean top-down view
- The floating PiP button itself is hidden (no point showing it inside PiP)

### Native Side — `MainActivity.kt`

```kotlin
// Method channel handler
"enablePip"  → pipEnabled = true
"disablePip" → pipEnabled = false
"enterPip"   → enterPictureInPictureMode(9:16 aspect ratio)

// Auto-enter on Home press
override fun onUserLeaveHint() {
    if (pipEnabled) enterPip()
}

// Notify Flutter of mode change
override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean) {
    eventSink?.success(isInPictureInPictureMode)
}
```

Aspect ratio is set to **9:16** (portrait) to match the map view.

---

## UI — Floating PiP Button

A white circle button with `picture_in_picture_alt_rounded` icon, positioned as a `Positioned` widget in the root `Stack`:

- `top`: `MediaQuery padding.top + 72` — sits just below the top nav bar
- `right: 16`
- Visible whenever `!_inPipMode` (all states: idle, navigating, en_route, in_trip)
- Hidden automatically when PiP is active (the whole overlay is gone)

---

## State Flow

```
App idle / navigating
        │
        ▼
  Driver taps PiP button
  OR presses Home (pipEnabled = true)
        │
        ▼
  enterPictureInPictureMode()  ← native
        │
        ▼
  onPictureInPictureModeChanged(true)
        │
        ▼
  eventSink pushes true → Flutter
        │
        ▼
  _inPipMode = true
  widget.onPipChanged(true)
  UI collapses to map-only
        │
        ▼
  Driver taps PiP window (Android expands)
        │
        ▼
  onPictureInPictureModeChanged(false)
        │
        ▼
  _inPipMode = false → full UI restored
```

---

## Requirements

- Android API 26+ (Oreo) — `Build.VERSION_CODES.O` check in `enterPip()`
- `android:supportsPictureInPicture="true"` must be set in `AndroidManifest.xml` on the `<activity>` tag
- `android:configChanges` must include `screenSize|smallestScreenSize|screenLayout|orientation` to prevent activity recreation on PiP resize

---

## Files

| File | Role |
|---|---|
| `lib/driver_navigation_screen.dart` | Flutter PiP logic, channel setup, UI gating on `_inPipMode` |
| `android/app/src/main/kotlin/com/fastrider/app/MainActivity.kt` | Native PiP entry, event emission, auto-enter on Home |

# koom

Local-first macOS screen recorder built with SwiftUI, ScreenCaptureKit, and AVFoundation.

## What works

- Floating control panel built with SwiftUI
- Select a monitor, camera, and microphone
- Always-on camera overlay pinned to the bottom-left of the selected monitor
- Start, pause, resume, stop, and restart recording
- Save recordings locally to `~/Movies/koom/*.mp4`
- Restore selected monitor, camera, and microphone between app launches
- Build and launch entirely from the terminal

## Run

```bash
./scripts/run.sh
```

That command:

1. Builds the Swift package with `swift build`
2. Bundles a real macOS app at `.build/koom.app`
3. Runs the app executable in the foreground
4. Streams app logs into the terminal

`Ctrl-C` in that terminal will terminate `koom`.

You can also just build the app bundle without launching it:

```bash
./scripts/build-app.sh
```

## First launch permissions

macOS will require permission for:

- Screen recording
- Camera
- Microphone

If screen capture is denied, approve koom in:

- `System Settings > Privacy & Security > Screen & System Audio Recording`

If camera or microphone access is denied, approve koom in:

- `System Settings > Privacy & Security > Camera`
- `System Settings > Privacy & Security > Microphone`

After granting screen recording access, relaunch koom.

## Current MVP scope

This repo only implements the local recording workflow. It does not yet include:

- ffmpeg post-processing
- Uploads
- Share links
- A hosted viewer

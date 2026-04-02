# koom

`koom` is a local macOS screen recorder built with SwiftUI, AVFoundation, and ScreenCaptureKit. It records a selected display to disk, can show an on-screen camera bubble, and can optionally capture microphone narration.

## Requirements

- macOS 13 or newer
- Screen Recording permission
- Camera permission when using the face overlay
- Microphone permission when recording narration

## Development

- Build app bundle: `./scripts/build-app.sh`
- Run app in foreground: `./scripts/run.sh`

## Recording Output

The current implementation writes the final recording directly to disk as an H.264 MP4 in real time. There is no later export, resize, transcode, or "optimize for sharing" pass after capture completes.

### Saved file

- Container: MP4
- Output path: `~/Movies/koom/koom_YYYY-MM-DD_HH-mm-ss.mp4`
- Video codec: H.264 (`AVVideoCodecType.h264`)
- H.264 profile: High Auto Level
- Cursor: included
- Screen/system audio from ScreenCaptureKit: disabled
- Microphone audio: optional, encoded with AVFoundation's recommended MP4-compatible writer settings

### Resolution

Video is recorded at the selected display's native capture size. The recorder copies `display.width` and `display.height` from `ScreenCaptureKit` directly into both the stream configuration and the asset writer. There is no fixed 1080p or 4K preset and no downscaling step.

That means:

- It is 4K only when the selected display is 4K.
- On higher-resolution displays, the saved file will also use that higher resolution.

### Frame cadence

- Target frame rate: 30 fps
- Maximum keyframe interval: 60 frames, or about every 2 seconds at 30 fps

### Video bitrate

The current target average video bitrate is:

```text
max(width * height * 4, 8_000_000) bits per second
```

Approximate examples:

- 1920x1080: about 8.3 Mb/s, around 62 MB/min
- 2560x1440: about 14.7 Mb/s, around 111 MB/min
- 3840x2160: about 33.2 Mb/s, around 249 MB/min

Actual file size will vary with content complexity and any audio track, but these numbers are a reasonable guide for the current implementation.

### Practical takeaway

The saved asset is not raw or lossless. It is already compressed during capture, so it is not "absolutely gigantic" in the sense of an uncompressed or ProRes master. However, because the recorder preserves the full selected display resolution and uses a meaningful bitrate, files can still become fairly large on 4K and higher-resolution displays.

In short: the current output is best described as direct-to-H.264 at native display resolution, not as a raw master that is expected to be optimized later.

# Camera Shader Investigation

Date: 2026-04-02

## Summary

It is possible to apply shader-style effects to the live camera feed in `koom`, but not with the current camera preview path as implemented today.

The current implementation renders the camera directly through `AVCaptureVideoPreviewLayer`, which is a display layer and not a programmable frame-processing pipeline. There is no `AVCaptureVideoDataOutput`, no direct handling of `CMSampleBuffer` camera frames, and no Metal/Core Image rendering stage where a fragment shader can be inserted.

## Current Architecture

### Camera preview

The live camera bubble is driven by an `AVCaptureSession` in `Sources/koom/CameraOverlay.swift`.

- `CameraPreviewManager` owns the session and only adds an `AVCaptureDeviceInput`.
- `CameraPreviewView` hosts a custom `NSView`.
- `CameraPreviewHostView` sets its backing layer to `AVCaptureVideoPreviewLayer`.
- The preview layer is configured with `.resizeAspectFill` and mirrored for the front camera effect.

Relevant code:

- `Sources/koom/CameraOverlay.swift:5`
- `Sources/koom/CameraOverlay.swift:135`
- `Sources/koom/CameraOverlay.swift:151`

### Recording

Recording is a separate pipeline in `Sources/koom/ScreenRecorder.swift`.

- Screen video comes from `ScreenCaptureKit`.
- The recorder captures the selected display using `SCStream`.
- Screen frames are appended to an `AVAssetWriterInput`.
- Camera frames are not currently fed into the writer as a distinct video source.

Relevant code:

- `Sources/koom/ScreenRecorder.swift:63`
- `Sources/koom/ScreenRecorder.swift:82`
- `Sources/koom/ScreenRecorder.swift:86`

## What This Means

### What works today

- A live camera preview overlay appears in its own floating window.
- The preview is lightweight because AVFoundation handles display directly.

### What does not exist today

- Per-frame camera image processing.
- A programmable shader hook.
- A Metal render pass for the camera image.
- A Core Image filter stage for the camera image.

## Conclusion

Shaders are not available out of the box with the current implementation.

To support fragment-shader-style effects, the camera preview path needs to move away from `AVCaptureVideoPreviewLayer` and into a custom rendering pipeline.

## Smallest Refactor That Enables Effects

1. Keep `AVCaptureSession` as the camera source.
2. Add an `AVCaptureVideoDataOutput` to receive camera frames as `CMSampleBuffer`.
3. Convert frames to `CVPixelBuffer` or textures.
4. Render them in a custom view.
5. Apply effects in either:
   - Metal via `MTKView` and a custom shader, or
   - Core Image backed by Metal for simpler filter-style effects.

## Recommended Direction

If the goal is "spice up the camera bubble" with effects like scanlines, chromatic aberration, glitching, color grading, or distortion:

- Use a custom `MTKView` renderer if the effects should be fully custom and shader-driven.
- Use Core Image first if the goal is to ship simpler GPU-accelerated filters quickly.

Given the current overlay size is small, the performance budget should be favorable for either approach.

## Recording Implications

Inference from the current code:

- The control panel window is explicitly excluded from sharing with `window.sharingType = .none` in `Sources/koom/AppModel.swift:83`.
- The camera overlay window does not currently set the same exclusion in `Sources/koom/CameraOverlay.swift`.

That suggests the camera overlay likely appears in the recorded screen output because recording is display-based, not app-composited. This should be verified in practice before building a more advanced filtered camera pipeline.

## Suggested Next Spike

Build a small proof of concept that:

1. Replaces `AVCaptureVideoPreviewLayer` for the camera overlay only.
2. Uses `AVCaptureVideoDataOutput`.
3. Draws into an `MTKView`.
4. Applies one simple effect such as scanlines, RGB split, or mild glitch distortion.

This would answer the practical questions quickly:

- Does the live preview remain smooth?
- Is latency acceptable?
- Does the filtered overlay still behave correctly inside the circular bubble?
- Does the recorded display capture the filtered overlay as expected?

## External References

- Apple Developer Documentation: `AVCaptureVideoPreviewLayer`
  - https://developer.apple.com/documentation/avfoundation/avcapturevideopreviewlayer
- Apple Developer Documentation: `AVCaptureVideoDataOutput`
  - https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput

## Possible shader to use

https://www.shadertoy.com/view/MddcRr - looks really good
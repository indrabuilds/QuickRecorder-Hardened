# QuickRecorder Hardened

An independent, Apple Silicon reliability fork of [QuickRecorder by lihaoyun6](https://github.com/lihaoyun6/QuickRecorder). Licensed under AGPL-3.0; see [LICENSE](LICENSE) and [upstream documentation](README_upstream.md).

This app has its own name and bundle identifier (`local.codex.QuickRecorderHardened`) and does not replace the original QuickRecorder. The upstream updater is disabled for this fork. Existing recording modes, formats, separate tracks, QMA packages, and controls are retained.

## Version 1.6.10

- Explicitly selected microphones use ScreenCaptureKit on macOS 15 and newer. Default microphone and echo cancellation retain their existing capture paths; older macOS retains legacy microphone capture.
- Stop closes the sample callback gate, awaits writer completion, then releases capture sources. Writer failures are reported and captured files remain available.
- Final outputs are checked with AVFoundation. Audio tracks are decoded completely; video must have a decodable first frame. Track counts and a positive duration are required. This does not guarantee that every video frame is decodable.
- Mixed/exported outputs use a separate staging file, are validated before publication, and refuse to overwrite an existing destination. Source files are retained after any failure.
- Video writes periodic fragments to improve recovery after interruption. Completed fragments survived a synthetic process interruption test; the final incomplete fragment may be lost.
- Recording checks writer failure, missing microphone sample arrivals, microphone format changes, and free space. Silence within arriving samples is valid. Recording requires 2 GiB available to start and attempts to stop before space falls below 1 GiB.
- Failure reports beside the recording contain technical metadata, not media data. Original recordings are not automatically repaired or deleted.
- The macOS 27 menu-bar click fix and adaptive black/white stop indicator from version 1.6.9.3 are retained.

## Build

GitHub Actions builds a Release app using Xcode on an Apple Silicon macOS runner and packages an ad-hoc signed application. No Intel build or Apple developer signing credentials are required. Open the successful run under Actions and download the app artifact. A matching source archive and checksums are included. The app is not notarized.

Locally, with full Xcode installed:

```sh
bash scripts/test-reliability.sh
bash scripts/build-arm64.sh
```

## Verification and remaining acceptance

The automated suite generates real AAC, H.264, and HEVC media using AVFoundation. It exercises 100 dual-audio writer finalizations, MOV/MP4 video with two audio tracks, invalid containers, missing tracks, destination conflicts, and interruption with completed fragments. These are synthetic media tests, not 100 microphone recordings.

A successful cloud build cannot establish hardware capture reliability. Before relying on this version for an important recording, verify these on the target Mac:

1. Audio-only system audio with Default microphone and with the explicitly selected built-in microphone, including QMA and mixed output.
2. Selected-window and selected-app audio/video with both microphone choices, with mixed and separate tracks.
3. Repeated short recordings, very short start/stop, and at least one hour-long recording. Check that all expected tracks are audible and aligned.
4. Pause/resume and menu-bar stop/pause on macOS 27.
5. Device disconnect or format/route change: a clear failure must preserve captured files rather than report success.

The original unfinalized recording reported by the user has no media index. This app update does not repair that historical file. Full audio decode validation can take additional time after long recordings.

# Future Scope: Custom Images + GIF Pipeline

## Goal
Allow users to send camera-roll images and short GIF animations.

## Candidate work

- iOS picker flow with size guardrails and progress UI.
- Static image path reuses current RGB565 processing + BLE transfer.
- GIF path decodes frames with `ImageIO`, converts each frame to RGB565.
- Firmware animation mode stores frames under `/anim` and loops by delay.

## Constraints

- BLE bandwidth is the main bottleneck (warn for large animations).
- Need robust cancel/resume behavior for long multi-frame sends.
- SD card writes for many frames must include integrity checks.

## Exit criteria

- Packet format draft for animation header + frame payloads.
- UI limits (max frames, max MB, estimated transfer time warnings).
- Benchmarks: transfer time and playback FPS on target hardware.

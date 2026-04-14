# Future Scope: Peer Cache Similarity

## Goal
Let two devices compare cached album keys and show a similarity score.

## Candidate work

- Define a compact BLE exchange protocol for cache key summaries.
- Use hashed key sets (not full song metadata) to reduce privacy risk.
- Compute overlap metric (`intersection / union`) and map to UI score.
- Show score + icon feedback on both participating devices.

## Constraints

- Device discovery and pairing UX must be explicit and user-approved.
- Large cache sets need chunked transfer and timeout handling.
- Must avoid exposing raw listening history identifiers over the air.

## Exit criteria

- Protocol sketch with packet sizes and retry rules.
- Privacy notes and opt-in UI flow.
- Prototype estimate for expected transfer time and memory footprint.

# Remote Play Audio Troubleshooting

Remote Play guest audio is streamed by Steam. The game can verify host-side playback, but it cannot force Steam transport to deliver audio to the guest.

## Host-side checks
- Ensure in-game audio is enabled and host volume is not effectively zero.
- Ensure the host default playback device is the correct active speakers/headphones device.
- Ensure the host speaker configuration is set to stereo if Steam Remote Play audio behaves inconsistently.

## Steam-side checks
- Verify Steam Remote Play audio streaming is enabled for the session.
- If the host logs show `audible=true`, non-zero `activeSources`, and first playback timestamps, but the guest still hears nothing, treat it as a Steam/client/OS transport issue rather than a gameplay-audio bug.

## Diagnostic sources
- `DebugConsole.log`
- Remote Play audio summary lines emitted by `audio_runtime.lua`

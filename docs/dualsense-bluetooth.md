# DualSense Bluetooth transport

This component lives in `controllers/dualsense`. It is built, packaged, checked
and removed with NotProton. The launcher and broker are native executables;
the injected facade contains arm64 and x86_64 slices. Python is used only for
development tests. There is no system driver, launch agent, or Homebrew runtime
dependency.

## Selecting a route

| Setup | Behavior |
| --- | --- |
| Direct controller access, one Bluetooth DualSense, no USB DualSense | Start the per-game bridge and expose a USB-style controller and haptic audio endpoint inside Wine. |
| Physical USB | Keep Wine's existing controller and audio path. |
| Steam Input | Keep NotProton's upstream Steam Input path; no raw bridge is started. |
| No supported controller, or more than one | Keep the original path. |
| `DSB_DISABLED=1 %command%` | Bypass the bridge for this launch. |

Use Steam's per-game Compatibility setting **Let games read controllers
directly** for games with their own DualSense support. The bridge forwards
input (including sensor data), supported output reports for triggers and
lights, traditional rumble, and haptic PCM supplied by the game. It does not
create trigger effects or map gyro to aiming for games that do not implement
those functions. Existing Steam Input mappings remain available on the
Steam Input route.

Steamworks' public `ISteamInput` API exposes rumble, LED color and
`SetDualSenseTriggerEffect`, but not arbitrary PCM sample streaming. A game
that only emits ordinary rumble has no original PCM waveform for this bridge
to recover. This implementation does not hook the native Steam process or
claim PCM support through Steam Input.

## Audio and scheduling

The Wine-local facade exposes a non-default four-channel audio endpoint.
Speaker channels 1/2 are ignored; haptic channels 3/4 retain their signed
waveforms. A 257-tap 1.2 kHz low-pass filter resamples them to 3 kHz, signed
8-bit stereo for Bluetooth. This is waveform PCM, not an intensity envelope,
but it is not bit-identical to the USB stream.

The broker sends a 206-byte `0x33` initialization report and 142-byte `0x32`
continuation reports, with sequence numbers and CRC. One writer serializes
PCM, trigger, LED and rumble updates. It sends only changed control fields,
so a trigger update cannot repeatedly overwrite Steam's previous LED color.
Silent streams do not send PCM; the audio mode is released after the actual
waveform tail. Buffering is bounded to 64 ms and late samples are discarded
instead of being replayed in a catch-up burst.

HID input, incoming UDP and control changes wake the writer through a Mach
semaphore. A `CFFileDescriptor` source wakes the receiving run loop. An audio
workgroup and realtime policy support deadline scheduling; they do not route
the waveform through Core Haptics. Timer-only wakeups previously suffered
roughly 100 ms delays while a foreground game owned Game Mode.

The measured Bluetooth link cannot sustain PCM at its reduced background
cadence. This implementation suspends PCM below 100 input reports/second and
discards queued audio on suspension. Game Mode eligibility is supplied by the
separate game-host component, but macOS decides whether to activate it. Check
`pcm.inputHz` and `pcm.suspended` in the status file when diagnosing silence.

Direct PCM is the default. `DSB_PCM=0 %command%` explicitly selects the older
Core Haptics envelope approximation for comparison. It is never substituted
silently. `calibration.json`'s optional `pcmGain` changes only this approximation,
not direct PCM or physical USB.

## Lifecycle and limits

The launcher holds one controller lock until the compatibility command exits.
The broker accepts only authenticated localhost packets from that session,
rejects replayed and stale data, and stops if its parent exits. Session records
are mode 0600 inside a mode 0700 directory. A confirmed physical disconnection
allows at most three reconnect attempts per minute on the same UDP port;
a stalled writer is not automatically restarted. Cleanup releases triggers
only when the game touched them.

Runtime files and diagnostics are under
`~/Library/Application Support/notproton/controllers/dualsense/`.
The `sessions/<AppID>-status.json` file contains transport counters. The
`sessions/<AppID>.json` file contains a temporary credential and should not be
included in issue reports. The launcher removes it on normal exit.

Current scope is one standard DualSense (`054c:0ce6`), on Apple Silicon,
tested with CrossOver 26.3 Rosetta. DualSense Edge, multiple controllers,
mid-game USB/Bluetooth switching and other Wine audio backends have not been
validated. Connect using the desired transport before launching the game.
The audio facade implements the CoreAudio AudioUnit output path used by the
tested Wine runtime; it is not a general macOS virtual sound device.

Some games additionally depend on Windows controller/audio association
metadata that Wine does not supply. The bridge does not universally repair
that association. A previously tested game-specific memory patch that chooses
the correct audio endpoint is intentionally excluded, as are bow curves and
gyro-to-mouse helpers. There are no game names or executable hashes in the
runtime dispatch logic.

## Build and verification

`make dualsense` builds the runtime. `make app-payload` includes it in the
installer and integrity checks. `make dualsense-check` exercises only fake
brokers and dry transports: it never sends effects to a physical controller.
Checks cover both CPU architectures' audio routing, speaker isolation,
signed resampling, CRC and sequence wrap, authentication, stale/replayed
packets, changed LED fields, exact trigger bytes, silence/restart, deferred
timer wakeups, route selection, private credentials, locking and cleanup.

The transport before repackaging was tested on macOS 27 with CrossOver 26.3
Rosetta and a standard DualSense: an eight-second recorded sequence and live
gameplay were felt and confirmed by the tester, including triggers and LED
stability. A fresh normal Steam launch sent 332 PCM reports with zero HID
errors or discarded frames and maximum packet lag of 7.93 ms. These are
results for that setup, not evidence that every game works. The new native
supervisor and packaged installer also require a fresh hardware smoke test
before a binary release.

## References

- [Steam Input API](https://partner.steamgames.com/doc/api/ISteamInput)
- [SDL DualSense backend](https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/SDL_hidapi_ps5.c)
- [Linux PlayStation HID driver](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-playstation.c)
- [dualsensectl](https://github.com/nowrep/dualsensectl/blob/main/main.c)

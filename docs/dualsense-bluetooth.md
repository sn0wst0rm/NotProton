# DualSense Bluetooth transport

NotProton builds and packages `controllers/dualsense` with its runtime.
The launcher and broker run per game session; the injected facade contains
arm64 and x86_64 slices.

## Source layout

| File | Responsibility |
| --- | --- |
| `launch.swift` | Route selection, private session credentials, child processes, reconnect limits. |
| `bridge.m` | Wine-local HID identity and report translation; authenticated packet sender. |
| `AudioFacade.m` | Wine's four-channel CoreAudio endpoint, format validation and render thread lifecycle. |
| `broker.m` | Session setup, authenticated receive loop, source mixing, control deltas and diagnostics. |
| `PCMTransport.m` | Single physical output writer, bounded audio FIFO and Bluetooth deadlines. |
| `PCM.h`, `Controls.h`, `protocol.h` | Sample conversion, output field layout and local wire format. |
| `Bridge.h`, `BrokerInternal.h` | Small internal boundaries between translation units. |

The session run loop owns source state. One writer owns Bluetooth sequence
numbers and physical output. `outputLock` protects the FIFO and control
snapshots; cross-thread shutdown flags and counters are atomic. AudioUnit
clients serialize each unit's configuration/lifecycle as with the underlying
API; the render thread reads fixed format/callback data and an atomic volume.
Changing those stream properties during playback is rejected. Uninitializing
or disposing an audio unit stops and joins its renderer. Device master/channel
volume, mute and the render callback's silence flag are applied before sample
conversion.

## Selecting a route

| Setup | Behavior |
| --- | --- |
| Direct controller access, one Bluetooth DualSense, no USB DualSense | Start the per-game bridge and expose a USB-style controller and haptic audio endpoint inside Wine. |
| Physical USB | Keep Wine's existing controller and audio path. |
| Steam Input | Keep Steam's virtual controller path; no raw bridge is started. |
| No supported controller, or more than one | Keep the original path. |
| `DSB_DISABLED=1 %command%` | Bypass the bridge for this launch. |

Use Steam's per-game Compatibility setting **Let games read controllers
directly** for games with their own DualSense support. The bridge forwards
input (including sensor data), supported output reports for triggers and
lights, traditional rumble, and haptic PCM supplied by the game. Trigger
effects and gyro-to-aim mappings depend on the game's implementation.
Steam Input mappings are available on the Steam Input route.

Steamworks' public `ISteamInput` API exposes rumble, LED color and
`SetDualSenseTriggerEffect`, but not arbitrary PCM sample streaming. PCM
therefore uses the direct-controller route.

## Audio and scheduling

The Wine-local facade exposes a non-default four-channel audio endpoint.
Speaker channels 1/2 are ignored; haptic channels 3/4 retain their signed
waveforms. A 257-tap 1.2 kHz low-pass filter resamples them to 3 kHz, signed
8-bit stereo for Bluetooth, preserving the waveform within that format's
bandwidth and precision.

The broker sends a 206-byte `0x33` initialization report and 142-byte `0x32`
continuation reports, with sequence numbers and CRC. One writer serializes
PCM, trigger, LED and rumble updates. It sends only changed control fields,
so a trigger update cannot repeatedly overwrite Steam's previous LED color.
Silent streams do not send PCM; the audio mode is released after the actual
waveform tail. Buffering is bounded to 64 ms and late samples are discarded
instead of being replayed in a catch-up burst.

HID input, incoming UDP and control changes wake the writer through a Mach
semaphore. A `CFFileDescriptor` source wakes the receiving run loop. An audio
workgroup and realtime policy support deadline scheduling. Event-driven
wakeups avoid timer coalescing while a foreground game owns Game Mode.

The measured Bluetooth link cannot sustain PCM at its reduced background
cadence. This implementation suspends PCM below 100 input reports/second and
discards queued audio on suspension. Game Mode eligibility is supplied by the
separate game-host component, but macOS decides whether to activate it. Check
`pcm.inputHz` and `pcm.suspended` in the status file when diagnosing silence.

Direct PCM is the default. `DSB_PCM=0 %command%` selects Core Haptics envelope
conversion. The optional `pcmGain` in `calibration.json` controls the gain
of that conversion.

## Lifecycle and limits

The launcher holds one controller lock until the compatibility command exits.
The broker accepts only authenticated localhost packets from that session,
rejects replayed and stale data, and stops if its parent exits. Session records
are mode 0600 inside a mode 0700 directory. A confirmed physical disconnection
allows at most three reconnect attempts per minute on the same UDP port;
a stalled writer is not automatically restarted. The session loop checks the
write deadline independently, so a blocked IOKit call cannot hang shutdown. Cleanup releases triggers
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
tested Wine runtime.

Games that require Windows controller/audio association metadata may need
additional Wine support to select the haptic endpoint.

## Build and verification

`make dualsense` builds the runtime. `make app-payload` includes it in the
installer and integrity checks. `make dualsense-check` uses fake brokers and
dry transports and runs without controller hardware. Checks cover both CPU
architectures' audio routing, speaker isolation, signed/unsigned integer PCM
and float PCM, volume/mute, invalid formats, silent or short callbacks, stream
uninitialization, resampling, CRC and sequence wrap, authentication,
stale/replayed packets, independent rumble/LED updates, per-trigger cleanup,
exact trigger bytes, silence/restart, deferred timer wakeups, route selection,
private credentials, locking and cleanup. Mock HID tests cover report translation,
repeated reconnects and blocked-driver timeouts without opening a controller.

Transport prototypes were verified on macOS 27 with CrossOver 26.3 Rosetta
and a standard DualSense, using recorded PCM playback and live gameplay with
trigger and LED output. The packaged runtime still requires a hardware smoke
test before release.

## References

- [Steam Input API](https://partner.steamgames.com/doc/api/ISteamInput)
- [SDL DualSense backend](https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/SDL_hidapi_ps5.c)
- [Linux PlayStation HID driver](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-playstation.c)
- [dualsensectl](https://github.com/nowrep/dualsensectl/blob/main/main.c)

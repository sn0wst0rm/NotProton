# Game app identity under Wine

Wine may re-execute a GUI process through a temporary hardlink outside the
game's app bundle. The generated app already has the game's name and icon,
but the executable has Wine's embedded bundle identity. Declaring Game Mode
support only in the external Info.plist is therefore insufficient on the
tested macOS system.

The native `prepare-game-loader` helper updates the embedded metadata in a
separate staged copy, preserves entitlements, signs it, and replaces the
staged loader atomically.
`game-host.dylib` redirects Wine's temporary `execv` only when the executable
argument resolves inside `STEAM_COMPAT_INSTALL_PATH`. Other Wine services and
external launchers retain their original identities. This avoids assigning
the game icon to every service in the prefix.

Both helpers are built and included in the normal app payload. Installation
and integrity checks cover them, and removing NotProton removes them with its
support directory.

This declares eligibility and preserves application identity. macOS still
decides when to activate Game Mode. Fullscreen behavior and process layouts
vary between games. The original implementation was validated on an Apple
Silicon Mac with macOS 27 and CrossOver 26.3 Rosetta; other combinations need
hardware verification before claiming universal compatibility.

Run `make game-host-check` for executable scoping, hardlink isolation,
metadata, code signature, malformed-input and idempotency tests. Existing
launcher routing and environment tests must also pass.

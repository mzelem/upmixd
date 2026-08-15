# upmixd

System-wide stereo → 5.1 upmixer for macOS, built for a Vantec (C-Media
CM6206) USB 7.1 adapter driving 5.1 analog speakers.

macOS never upmixes: stereo sources only ever reach the front pair, even when
the output device runs 6 channels. `upmixd` fixes that for everything at once:

```
apps → BlackHole 2ch (system default output) → upmixd → USB Sound Device (6ch)
```

`upmixd` captures the system mix from [BlackHole](https://github.com/ExistentialAudio/BlackHole),
upmixes it (fronts passthrough, derived center, 120 Hz low-passed LFE,
15 ms-delayed rears), and plays the result on the adapter through a private
aggregate device (adapter clock, drift-compensated capture). The DSP lives in
`UpmixCore` and is fully unit-tested; the daemon is a thin CoreAudio shell.

The adapter itself needs no driver: it is a standard USB Audio Class 1.0
device whose 6/8-channel formats macOS supports natively — it just defaults
to the 2-channel alt setting. `upmixd` forces the 6ch/16-bit/48 kHz format on
startup.

## Install

```sh
brew install --cask blackhole-2ch   # needs password + coreaudiod restart
make test
make install                        # /usr/local/bin/upmixd + LaunchAgent
```

The LaunchAgent runs `upmixd --set-default`, which points the system default
output at BlackHole on login. Pick a different output in Sound settings any
time to bypass the upmixer; pick BlackHole again to come back.

Logs: `~/Library/Logs/upmixd.log`. Uninstall: `make uninstall`.

## Notes

- Channel order matches the CM6206 6ch alt setting: FL FR FC LFE RL RR.
- If the adapter is unplugged the daemon exits and launchd retries every 10 s
  until it reappears.
- Volume keys act on BlackHole while it is the default output; BlackHole
  applies that gain to the loopback stream itself.

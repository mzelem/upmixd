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
25 ms-delayed rears — see `upmixd --help` for the mix knobs), and plays the
result on the adapter through a private
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

## Equalizer and live tuning

All settings live in `~/.config/upmixd.conf` (created on first run; override
with `--config`). The daemon reloads it within ~2 seconds of saving — edit,
save, hear the change. Example:

```
rear_gain = 0.9
rear_delay_ms = 25.0
center_gain = 0.354
lfe_gain = 0.45

# equalizer: eq_band = <freq_hz> <gain_db> [<q>]   (up to 16 bands)
eq_preamp_db = -6.0
eq_band = 80 4
eq_band = 3000 -2
```

The EQ is a cascade of peaking filters applied to the stereo mix before
upmixing. The default preamp is a fixed -6 dB of headroom — within a fraction of a dB
of every built-in preset's worst case — so adjusting one band never shifts the level of the others.
Set `eq_preamp_db = auto` instead to have the daemon measure the worst-case
combined boost and attenuate by exactly that: guaranteed clip-free even with
overlapping boosted bands, at the cost of the overall level moving as you
change the EQ. Boosts beyond the fixed headroom on full-scale content hit a
hard full-scale limiter rather than distorting downstream. A bad edit never
takes audio down: invalid lines are logged and ignored.

Prefer sliders? `make install-panel` (no sudo) puts a menu-bar app in
`~/Applications` with 10 graphic-EQ sliders and the surround knobs; it just
writes this config file. Hand-authored bands it can't represent (custom
frequency, Q, or >12 dB) are preserved untouched. Remove with
`make uninstall-panel`.

## Docking and undocking

The daemon is resident and device-aware. Unplug the adapter (undock) and it
falls the default output back to the built-in speakers, so laptop audio keeps
working immediately. Plug it back in (dock) and it reattaches within about a
second — CoreAudio device notifications, not polling — and points the default
output back at BlackHole. No clicking around in Sound settings either way.

## Notes

- Channel order matches the CM6206 6ch alt setting: FL FR FC LFE RL RR.
- Volume keys act on BlackHole while it is the default output; BlackHole
  applies that gain to the loopback stream itself.
- launchd (`KeepAlive`) restarts the daemon only if it crashes or BlackHole
  itself disappears; device churn is handled in-process.

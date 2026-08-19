# Cast

Cast your desktop — with audio — to a Chromecast or any Google Cast device,
straight from the Omarchy bar.

Unlike Miracast-based casting, this works with the Google Cast protocol that
Chromecasts, Google TV, and Nest displays actually speak. Capture and encoding
run on the GPU via `gpu-screen-recorder` (the same engine as Omarchy's screen
recording), so it holds a steady frame rate with minimal CPU impact and no
root privileges.

## How it works

```
gpu-screen-recorder (GPU capture + h264/aac)
  → ffmpeg (remux to live HLS, no re-encode)
  → minimal LAN-only HTTP server (exists only while casting)
  → catt (tells the Cast device to play the stream)
```

The Cast protocol is pull-based — the device fetches media over HTTP — so a
local stream server is required by design. Expect ~3–5 seconds of latency;
that is inherent to Chromecast HLS buffering and fine for watching content,
but not for interactive use.

## Install

```
omarchy plugin add https://github.com/jakekeeys/omarchy-cast.git --enable
```

### Dependencies

- `gpu-screen-recorder` and `ffmpeg` — ship with Omarchy
- [`catt`](https://github.com/skorokithakis/catt) — `uv tool install catt`
  (or `pipx install catt`)

### Firewall

If `ufw` is active, the plugin opens the stream port (default 8089/tcp) to
private LAN ranges the first time the widget loads — you'll get a single
polkit prompt. The rules are tagged `jake-cast` and are removed automatically
(one more prompt) when you disable or remove the plugin.

## Usage

- **Left click** the bar icon to open the panel
- **Click a device** to select it as the target
- **The toggle** in the panel header starts and stops the cast
- **"Cast an area or window…"** picks a region, window, or monitor with the
  same picker Omarchy's screen recorder uses (bare click snaps to a window or
  monitor)
- **Right click** the bar icon to quick-toggle casting to the selected device
- **Middle click** to rescan for devices
- Keyboard: `j`/`k` move, `Enter` select, `t` toggle cast, `a` cast area,
  `s` rescan, `Esc` close

IPC, if you want to script it:

```
omarchy-shell jakekeeys.cast start "Living Room TV"
omarchy-shell jakekeeys.cast stop
omarchy-shell jakekeeys.cast status
```

## Configuration

Widget settings (bar settings UI, or inline in `~/.config/omarchy/shell.json`):

| Setting      | Default     | Notes                                    |
|--------------|-------------|------------------------------------------|
| `fps`        | `30`        | Capture frame rate                        |
| `resolution` | `1920x1080` | Output size limit (aspect preserved)      |
| `bitrate`    | `8000`      | CBR video bitrate in kbps                 |
| `port`       | `8089`      | Local HTTP port the device pulls from     |

## Remove

```
omarchy plugin remove jakekeeys.cast
```

## License

MIT

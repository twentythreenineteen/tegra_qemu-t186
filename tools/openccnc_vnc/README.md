# openccnc_vnc — Guest-side screen capture, touch injection, and web UI

These four scripts are **guest payloads**. They run **inside the Tegra186
guest** (the Parker/T186 Linux userspace booted by `launch_tegra186.sh`), not
on the QEMU host. They are not a host-side QEMU VNC server. They talk to the
guest's own Wayland compositor socket, its `/dev/uinput` device node, and its
D-Bus session bus.

They were ported verbatim from the working guest tool directory. Do not change
their logic without re-validating on the guest.

## Files

| File | Purpose |
|---|---|
| `frame_server.py` | Wayland `ccos_wm` / `hscreen` screen-capture client plus an HTTP web UI. Serves PNG frames (native 1920x720, optionally downscaled) and accepts tap/swipe and action requests from a browser. |
| `uinput_touch.py` | Pure-stdlib virtual multitouch touchscreen on `/dev/uinput` (Linux input protocol B, `INPUT_PROP_DIRECT`). Coordinates are in the 1920x720 captured-frame space. Also runnable as a CLI to send a single tap. |
| `actions.py` | D-Bus action registry. Each `@register(id, label)` function becomes a button in the web UI. Ships with a `screenshot` action that sends a key event via `ccos.api.hiac`. |
| `send_keypress.py` | Standalone D-Bus sender that emits a `SYSTEM_NOTIFY_KEY_APPS` key event through `ccos.api.hiac.ENGMODEMANAGER`. |

`frame_server.py` imports `uinput_touch` and `actions` from the same directory,
so keep all four files together.

## Dependencies (on the guest)

- Python 3 standard library only for `frame_server.py` and `uinput_touch.py`.
- `python3-dbus` (the `dbus` module) for `actions.py` and `send_keypress.py`.
- Access to the Wayland socket at the guest's runtime path (for example
  `/run/wayland-system`), to `/dev/uinput` (typically running as root), and to
  the session D-Bus with the `ccos.api.hiac` services available.

## Usage (run inside the guest)

Serve the web UI on port 8080 with 2x downscale (960x360 frames):

```sh
python3 frame_server.py 8080 2
```

Then open `http://<guest-ip>:8080` from a browser on the same network. The
server prints the URL it is serving on at startup.

Send a single tap at guest pixel coordinates (x=500, y=300):

```sh
python3 uinput_touch.py 500 300
```

Send a single key event through D-Bus (the `screenshot` action uses the same
path):

```sh
python3 send_keypress.py
```

## Notes

- The `frame_server.py` `main()` hardcodes a Head Unit screen type and a
  192.168.43.1 banner address. These are guest-network specifics, kept
  unchanged for fidelity to the working copy.
- Nothing here is needed on the host, and nothing here is started
  automatically by `launch_tegra186.sh`.

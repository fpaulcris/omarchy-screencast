#!/usr/bin/env python3
"""ScreenMirror: LAN JPEG stream for smart-TV browsers."""

from __future__ import annotations

import json
import os
import re
import signal
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOST = "0.0.0.0"
PORTS = [int(p) for p in os.environ.get("MIRROR_PORTS", "8080,8000,8090").split(",") if p]
WIDTH = os.environ.get("MIRROR_WIDTH", "1920")
HEIGHT = os.environ.get("MIRROR_HEIGHT", "1080")
FPS = os.environ.get("MIRROR_FPS", "20")
# Software fallback only. Lower qscale is sharper and heavier.
QSCALE = os.environ.get("MIRROR_QSCALE", "4")
VAAPI_DEVICE = "/dev/dri/renderD128"

def _runtime_dir() -> Path:
    base = os.environ.get("XDG_RUNTIME_DIR") or str(Path.home() / ".cache")
    return Path(base) / "screenmirror"


RUNTIME = _runtime_dir()
FIFO = RUNTIME / "live.mjpg"
ACCESS_LOG = RUNTIME / "access.log"
URL_FILE = RUNTIME / "url"
STATUS_FILE = RUNTIME / "status.json"
CAST_FILE = Path.home() / ".config" / "screenmirror" / "cast.json"
VIRTUAL_NAME = "screenmirror"
# A mirror output keeps this name but disappears from `hyprctl monitors`, so a
# later create is refused. The second name is only used when that happens.
_VIRTUAL_CANDIDATES = ("screenmirror", "castscreen")
_virtual_output_name = VIRTUAL_NAME
RESOLUTIONS = {(1280, 720), (1920, 1080), (2560, 1440), (3840, 2160)}
_MONITOR_NAME = re.compile(r"^[A-Za-z0-9_.-]+$")

# One long request. The browser paints each JPEG as it arrives, so the TV
# does not open a new connection or wait between pictures.
HTML = """<html>
<head>
<title>Screen Cast</title>
<style type="text/css">
html, body { margin: 0; padding: 0; width: 100%; height: 100%; background: #000; overflow: hidden; }
img { position: absolute; left: 0; top: 0; width: 100%; height: 100%; border: 0; object-fit: contain; }
</style>
</head>
<body bgcolor="#000000">
<img src="stream.mjpg" alt="">
</body>
</html>
"""

# Older TV browsers that ignore a multipart stream can open /poll instead.
POLL_HTML = """<html>
<head>
<title>Screen Cast</title>
<style type="text/css">
html, body { margin: 0; padding: 0; width: 100%; height: 100%; background: #000; overflow: hidden; }
img { position: absolute; left: 0; top: 0; width: 100%; height: 100%; border: 0; object-fit: contain; }
</style>
</head>
<body bgcolor="#000000">
<img id="a" alt="">
<script type="text/javascript">
var shown = document.getElementById('a');
function tick() {
  var next = new Image();
  next.onload = function() {
    shown.src = next.src;
    tick();
  };
  next.onerror = function() { setTimeout(tick, 400); };
  next.src = 'frame.jpg?n=' + (new Date()).getTime();
}
tick();
</script>
</body>
</html>
"""

_lock = threading.Lock()
_cond = threading.Condition(_lock)
_frame = b""
_frame_id = 0
_status_ip = ""
_status_output = ""
_listening = False
_status_lock = threading.Lock()
_stop = threading.Event()
_reload = threading.Event()
_reader_idle = threading.Event()
_proc: subprocess.Popen | None = None
_servers: list[ThreadingHTTPServer] = []
_cast_workspace = 0
_cast_virtual = False
_cast_follow = True
_cast_width = 1920
_cast_height = 1080
# Set while the user has opened the cast desktop on the laptop, so a later
# settle does not send them back to the desktop they just left.
_hold_laptop_workspace = 0
# Last monitor the user focused, taken from Hyprland's event socket. A monitor
# query is too late: focusing the cast desktop lands on the virtual screen, and
# the old focus pull had already returned to the laptop before the query ran.
_user_focus_monitor = ""
_user_focus_workspace = 0
# Desktop the user asked for by selecting it while it lived on the virtual
# screen. Hyprland focuses that screen and then, because the pointer never
# lands there, immediately focuses the laptop again. The second event is not
# the user choosing a different desktop.
_open_request = 0
_open_request_at = 0.0
_laptop_ws_seen = 0
# While this is set, new JPEGs are dropped and the TV keeps the last picture.
# Leaving the cast desktop must not stream the laptop's new desktop.
_hold_picture = False
# Our own focus changes must not look like the user opening the cast desktop.
_focus_quiet = 0
_layout_lock = threading.Lock()
_desktop_dirty = threading.Event()
_layout_failures = 0


def lan_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("1.1.1.1", 80))
        return s.getsockname()[0]
    finally:
        s.close()


def default_output() -> str:
    env = os.environ.get("MIRROR_OUTPUT")
    if env:
        return env
    try:
        mons = json.loads(subprocess.check_output(["hyprctl", "monitors", "-j"], text=True))
        for mon in mons:
            if mon.get("focused"):
                return mon["name"]
        if mons:
            return mons[0]["name"]
    except Exception:
        pass
    return "eDP-1"


def stream_fps(width: int, height: int) -> str:
    """Keep large pictures small enough for this Wi-Fi to stay current."""
    pixels = width * height
    if pixels >= 3840 * 2160 * 9 // 10:
        return "8"
    if pixels >= 2560 * 1440 * 9 // 10:
        return "12"
    return os.environ.get("MIRROR_FPS", "20")


def vaapi_quality(width: int, height: int) -> str:
    """Sharper JPEG below 1080p. Larger frames drop the quality a step so the TV can keep up."""
    if width * height > 1920 * 1080:
        return "80"
    return "90"


def output_size(output: str) -> tuple[int, int] | None:
    try:
        mons = json.loads(subprocess.check_output(["hyprctl", "monitors", "-j"], text=True))
    except Exception:
        return None
    for mon in mons:
        if mon.get("name") == output:
            return int(mon["width"]), int(mon["height"])
    return None


def hypr_json(command: str) -> list:
    try:
        loaded = json.loads(subprocess.check_output(["hyprctl", command, "-j"], text=True))
    except Exception:
        return []
    return loaded if isinstance(loaded, list) else []


def hypr_dispatch(call: str) -> None:
    subprocess.run(
        ["hyprctl", "dispatch", call],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def hypr_eval(code: str) -> None:
    subprocess.run(
        ["hyprctl", "eval", code],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def panel_size() -> tuple[int, int]:
    """The laptop panel's current size. Auto casting uses this."""
    laptop = laptop_monitor()
    if not laptop:
        return 1920, 1080
    width = int(laptop.get("width") or 0)
    height = int(laptop.get("height") or 0)
    if width < 1 or height < 1:
        return 1920, 1080
    return width, height


def read_cast() -> tuple[int | None, int, int]:
    """Return the cast desktop, or None when the cast should follow this screen.

    A saved desktop number always means that desktop, even when it is the one
    currently on the laptop. Following the laptop is a separate choice.
    Auto, the default, uses this laptop panel's resolution.
    """
    width, height = 1920, 1080
    auto = True
    try:
        loaded = json.loads(CAST_FILE.read_text(encoding="utf-8"))
    except Exception:
        return None, *panel_size()
    if not isinstance(loaded, dict):
        return None, *panel_size()
    if "auto" in loaded:
        auto = bool(loaded.get("auto"))
    if not auto:
        try:
            size = (int(loaded.get("width")), int(loaded.get("height")))
        except (TypeError, ValueError):
            size = (width, height)
        if size in RESOLUTIONS:
            width, height = size
    else:
        width, height = panel_size()
    if loaded.get("follow") is True:
        return None, width, height
    try:
        chosen = int(loaded.get("workspace"))
    except (TypeError, ValueError):
        chosen = 0
    if 1 <= chosen <= 10:
        return chosen, width, height
    return None, width, height


def laptop_monitor(mons: list | None = None) -> dict | None:
    mons = hypr_json("monitors") if mons is None else mons
    for mon in mons:
        if str(mon.get("name", "")).startswith("eDP"):
            return mon
    for mon in mons:
        name = str(mon.get("name", ""))
        if name and name not in _VIRTUAL_CANDIDATES and not name.startswith("HEADLESS"):
            return mon
    return mons[0] if mons else None


def focus_laptop_window(workspace: int) -> None:
    """Point focus at a window on the laptop's own desktop.

    Closing the cast panel gives focus back to the last window. If that window
    belongs to the desktop being cast, the laptop switches to it.
    """
    if workspace < 1:
        return
    try:
        clients = json.loads(subprocess.check_output(["hyprctl", "clients", "-j"], text=True))
    except Exception:
        return
    address = ""
    if isinstance(clients, list):
        for client in clients:
            try:
                ws = int((client.get("workspace") or {}).get("id") or 0)
            except (TypeError, ValueError):
                continue
            if ws != workspace or client.get("mapped") is False:
                continue
            address = str(client.get("address") or "")
            if address:
                break
    global _focus_quiet
    _focus_quiet += 1
    try:
        if address:
            selector = address if address.startswith("address:") else f"address:{address}"
            hypr_dispatch(f'hl.dsp.focus({{ window = "{selector}" }})')
        else:
            focus_workspace(workspace)
    finally:
        _focus_quiet -= 1


def focus_workspace(workspace: int) -> None:
    global _focus_quiet
    if workspace < 1:
        return
    _focus_quiet += 1
    try:
        hypr_dispatch(f'hl.dsp.focus({{ workspace = "{int(workspace)}" }})')
    finally:
        _focus_quiet -= 1


def hypr_monitors(include_hidden: bool = False) -> list:
    command = ["hyprctl", "monitors", "all", "-j"] if include_hidden else ["hyprctl", "monitors", "-j"]
    try:
        loaded = json.loads(subprocess.check_output(command, text=True))
    except Exception:
        return []
    return loaded if isinstance(loaded, list) else []


def _usable_output(mon: dict | None) -> bool:
    if not mon:
        return False
    mirror = mon.get("mirrorOf")
    return mirror in (None, "", "none")


def virtual_monitor(mons: list | None = None) -> dict | None:
    mons = hypr_json("monitors") if mons is None else mons
    for mon in mons:
        if mon.get("name") == _virtual_output_name and _usable_output(mon):
            return mon
    return None


def pin_monitor(mon: dict) -> None:
    name = str(mon.get("name") or "")
    if not _MONITOR_NAME.fullmatch(name):
        return
    x, y = int(mon.get("x") or 0), int(mon.get("y") or 0)
    scale = float(mon.get("scale") or 1)
    hypr_eval(f'hl.monitor({{ output = "{name}", position = "{x}x{y}", scale = {scale} }})')


def workspace_table() -> dict[int, tuple[str, int]]:
    found: dict[int, tuple[str, int]] = {}
    for item in hypr_json("workspaces"):
        try:
            ident = int(item.get("id") or 0)
        except (TypeError, ValueError):
            continue
        if ident > 0:
            found[ident] = (str(item.get("monitor") or ""), int(item.get("windows") or 0))
    return found


def virtual_needs_scale_fix() -> bool:
    """Headless screens default to scale 2, which makes the cast capture half the pixels."""
    virt = virtual_monitor()
    if virt is None:
        return False
    return abs(float(virt.get("scale") or 0) - 1.0) >= 0.01


def laptop_snapshot() -> dict | None:
    laptop = laptop_monitor()
    return dict(laptop) if laptop else None


def settle_laptop(saved: dict | None) -> None:
    """Put the laptop panel back. A desktop that now lives on the virtual screen stays there."""
    if not saved:
        return
    ws = int((saved.get("activeWorkspace") or {}).get("id") or 0)
    now = laptop_monitor()
    if now and (
        int(now.get("x") or 0) != int(saved.get("x") or 0)
        or int(now.get("y") or 0) != int(saved.get("y") or 0)
    ):
        pin_monitor(saved)
        now = laptop_monitor()
    if not now:
        return
    name = str(now.get("name") or "")
    if not now.get("focused") and _MONITOR_NAME.fullmatch(name):
        global _focus_quiet
        _focus_quiet += 1
        try:
            hypr_dispatch(f'hl.dsp.focus({{ monitor = "{name}" }})')
        finally:
            _focus_quiet -= 1
        now = laptop_monitor()
        if not now:
            return
    if _hold_laptop_workspace:
        return
    now_ws = int((now.get("activeWorkspace") or {}).get("id") or 0)
    if ws < 1 or now_ws == ws:
        return
    host, _windows = workspace_table().get(ws, ("", 0))
    if host == str(now.get("name") or ""):
        focus_workspace(ws)


def configure_virtual(laptop: dict, width: int, height: int) -> None:
    name = str(laptop.get("name") or "")
    if not _MONITOR_NAME.fullmatch(name):
        raise RuntimeError(f"unexpected monitor name {name!r}")
    x, y = int(laptop.get("x") or 0), int(laptop.get("y") or 0)
    scale = float(laptop.get("scale") or 1)
    pos_x = x + int(laptop.get("width") or 0)
    existing = virtual_monitor()
    if existing is not None:
        same_mode = (int(existing.get("width") or 0), int(existing.get("height") or 0)) == (width, height)
        same_place = int(existing.get("x") or 0) == pos_x and int(existing.get("y") or 0) == y
        # A headless screen with no physical size comes up at scale 2. wf-recorder
        # then captures 960x540 and the encoder enlarges it, which is the soft picture.
        same_scale = abs(float(existing.get("scale") or 0) - 1.0) < 0.01
        if same_mode and same_place and same_scale:
            return
    code = (
        f'hl.monitor({{ output = "{name}", position = "{x}x{y}", scale = {scale} }}); '
        f'hl.monitor({{ output = "{_virtual_output_name}", mode = "{int(width)}x{int(height)}@60", '
        f'position = "{pos_x}x{y}", scale = 1 }})'
    )
    hypr_eval(code)


# One compositor transaction. Hyprland will not show the same desktop on two
# screens, and set_workspace does not move a desktop: it only points the
# screen at a desktop that already lives there. Focusing a desktop follows
# the screen that owns it, which is how the cursor ended up on the headless
# output and later keypresses shuffled windows onto it.
_LAYOUT_LUA = r"""
local VIRTUAL = "__OUTPUT__"
local MODE = "__MODE__"
local WANTED = __WANTED__

local function laptop_mon()
  local mons = hl.get_monitors()
  for _, mon in ipairs(mons) do
    if mon.name:sub(1, 3) == "eDP" then return mon end
  end
  for _, mon in ipairs(mons) do
    if mon.name ~= VIRTUAL and mon.name:sub(1, 8) ~= "HEADLESS" then return mon end
  end
  return mons[1]
end

local function cursor_on(mon, x, y)
  if not mon or not x or not y then return false end
  local scale = mon.scale
  if not scale or scale == 0 then scale = 1 end
  local w = mon.width / scale
  local h = mon.height / scale
  return x >= mon.x and y >= mon.y and x < mon.x + w and y < mon.y + h
end

local function focus_laptop(laptop)
  local active = hl.get_active_monitor()
  if not active or active.name ~= laptop.name then
    hl.dispatch(hl.dsp.focus({ monitor = laptop.name }))
  end
end

local function restore_cursor(x, y, laptop)
  if cursor_on(laptop, x, y) then
    hl.dispatch(hl.dsp.cursor.move({ x = x, y = y }))
  end
end

local function free_id()
  local used = {}
  for _, ws in ipairs(hl.get_workspaces()) do
    if ws.id and ws.id > 0 then used[ws.id] = true end
  end
  for i = 1, 20 do
    if not used[i] then return i end
  end
  return 21
end

local function park_id(laptop, wanted)
  local below, above = nil, nil
  for _, ws in ipairs(hl.get_workspaces()) do
    if ws.id and ws.id > 0 and not ws.special and ws.monitor and ws.monitor.name == laptop.name and ws.id ~= wanted then
      if ws.id < wanted and (not below or ws.id > below) then below = ws.id end
      if ws.id > wanted and (not above or ws.id < above) then above = ws.id end
    end
  end
  return below or above or free_id()
end

local function owned_by_virtual(ident)
  local ws = hl.get_workspace(tostring(ident))
  return ws and ws.monitor and ws.monitor.name == VIRTUAL
end

local point = hl.get_cursor_pos()
local cursor_x = point and point.x or nil
local cursor_y = point and point.y or nil
local laptop = laptop_mon()
if not laptop then error("no laptop screen") end

if MODE == "focus" then
  focus_laptop(laptop)
  __line = "ok focus"
  return
end

if MODE == "borrow" then
  -- The user opened the cast desktop. Put it on the laptop and show it there.
  local ws = hl.get_workspace(tostring(WANTED))
  if ws and ws.monitor and ws.monitor.name ~= laptop.name then
    hl.dispatch(hl.dsp.workspace.move({ workspace = tostring(WANTED), monitor = laptop.name }))
  end
  focus_laptop(laptop)
  local now = laptop_mon()
  if not now or not now.active_workspace or now.active_workspace.id ~= WANTED then
    hl.dispatch(hl.dsp.focus({ workspace = tostring(WANTED) }))
  end
  __line = "ok borrow"
  return
end

if MODE == "release" then
  focus_laptop(laptop)
  local virt = hl.get_monitor(VIRTUAL)
  if not virt then
    restore_cursor(cursor_x, cursor_y, laptop)
    __line = "ok release"
    return
  end
  local active_id = virt.active_workspace and virt.active_workspace.id or 0
  local inactive = {}
  for _, ws in ipairs(hl.get_workspaces()) do
    if ws.id and ws.id > 0 and not ws.special and ws.monitor and ws.monitor.name == VIRTUAL and ws.id ~= active_id then
      inactive[#inactive + 1] = ws.id
    end
  end
  for _, id in ipairs(inactive) do
    hl.dispatch(hl.dsp.workspace.move({ workspace = tostring(id), monitor = laptop.name }))
  end
  virt = hl.get_monitor(VIRTUAL)
  if virt and virt.active_workspace and virt.active_workspace.id and virt.active_workspace.id > 0 then
    local owner = virt.active_workspace.monitor
    if owner and owner.name == VIRTUAL then
      hl.dispatch(hl.dsp.workspace.move({ workspace = tostring(virt.active_workspace.id), monitor = laptop.name }))
    end
  end
  focus_laptop(laptop)
  restore_cursor(cursor_x, cursor_y, laptop_mon())
  __line = "ok release"
  return
end

local virt = hl.get_monitor(VIRTUAL)
if not virt then error("virtual screen is missing") end

local function has_stray()
  for _, ws in ipairs(hl.get_workspaces()) do
    if ws.id and ws.id > 0 and ws.id ~= WANTED and not ws.special and ws.monitor and ws.monitor.name == VIRTUAL then
      return true
    end
  end
  return false
end

local shown = virt.active_workspace and virt.active_workspace.id or 0
if shown == WANTED and owned_by_virtual(WANTED) and not has_stray() then
  local active = hl.get_active_monitor()
  if not active or active.name ~= laptop.name then
    focus_laptop(laptop)
  end
  __line = "ok same"
  return
end

local stay = laptop.active_workspace and laptop.active_workspace.id or 0
local parked = 0
if stay == WANTED then
  parked = park_id(laptop, WANTED)
  focus_laptop(laptop)
  hl.dispatch(hl.dsp.focus({ workspace = tostring(parked) }))
  laptop = laptop_mon()
  stay = laptop and laptop.active_workspace and laptop.active_workspace.id or 0
  if stay == WANTED then error("could not leave the desktop before moving it") end
end

if not owned_by_virtual(WANTED) then
  local ws = hl.get_workspace(tostring(WANTED))
  if ws then
    hl.dispatch(hl.dsp.workspace.move({ workspace = tostring(WANTED), monitor = VIRTUAL }))
  else
    hl.dispatch(hl.dsp.focus({ monitor = VIRTUAL }))
    hl.dispatch(hl.dsp.focus({ workspace = tostring(WANTED) }))
    focus_laptop(laptop)
    if stay > 0 then
      local stay_ws = hl.get_workspace(tostring(stay))
      if stay_ws and stay_ws.monitor and stay_ws.monitor.name == laptop.name then
        local now = hl.get_monitor(laptop.name)
        if not now or not now.active_workspace or now.active_workspace.id ~= stay then
          hl.dispatch(hl.dsp.focus({ workspace = tostring(stay) }))
        end
      end
    end
  end
end

if not owned_by_virtual(WANTED) then error("desktop did not move onto the virtual screen") end

virt = hl.get_monitor(VIRTUAL)
if not virt or not virt.active_workspace or virt.active_workspace.id ~= WANTED then
  virt = hl.get_monitor(VIRTUAL)
  virt:set_workspace({ workspace = tostring(WANTED) })
end

local leftovers = {}
for _, ws in ipairs(hl.get_workspaces()) do
  if ws.id and ws.id > 0 and ws.id ~= WANTED and not ws.special and ws.monitor and ws.monitor.name == VIRTUAL then
    leftovers[#leftovers + 1] = ws.id
  end
end
for _, id in ipairs(leftovers) do
  hl.dispatch(hl.dsp.workspace.move({ workspace = tostring(id), monitor = laptop.name }))
end

laptop = laptop_mon()
focus_laptop(laptop)
if stay > 0 then
  local stay_ws = hl.get_workspace(tostring(stay))
  if stay_ws and stay_ws.monitor and stay_ws.monitor.name == laptop.name then
    local now = hl.get_monitor(laptop.name)
    if not now or not now.active_workspace or now.active_workspace.id ~= stay then
      hl.dispatch(hl.dsp.focus({ workspace = tostring(stay) }))
    end
  end
end
laptop = laptop_mon()
restore_cursor(cursor_x, cursor_y, laptop)
local vnow = hl.get_monitor(VIRTUAL)
local lnow = laptop_mon()
local focus = hl.get_active_monitor()
__line = "ok park=" .. tostring(parked)
  .. " virtual=" .. tostring(vnow and vnow.active_workspace and vnow.active_workspace.id or 0)
  .. " laptop=" .. tostring(lnow and lnow.active_workspace and lnow.active_workspace.id or 0)
  .. " focus=" .. tostring(focus and focus.name or "")
"""


def _lua_quote(value: str) -> str:
    return "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"


def run_layout(mode: str, wanted: int) -> str:
    """Move desktops in one Hyprland script. `show` puts one desktop on the virtual screen."""
    global _focus_quiet
    if mode not in {"show", "release", "focus", "borrow"}:
        raise RuntimeError(f"bad layout mode {mode}")
    if mode == "show" and not 1 <= int(wanted) <= 10:
        raise RuntimeError(f"desktop {wanted} is out of range")
    RUNTIME.mkdir(mode=0o700, exist_ok=True)
    result = RUNTIME / "layout.txt"
    result.unlink(missing_ok=True)
    output_name = _virtual_output_name if _virtual_output_name in _VIRTUAL_CANDIDATES else VIRTUAL_NAME
    body = (
        _LAYOUT_LUA.replace("__MODE__", mode)
        .replace("__WANTED__", str(int(wanted)))
        .replace("__OUTPUT__", output_name)
    )
    wrapper = (
        "local __line = 'ok'\n"
        "local __ok, __err = pcall(function()\n"
        + body
        + "\nend)\n"
        f"local __f = io.open({_lua_quote(str(result))}, 'w')\n"
        "if __f then\n"
        "  if __ok then __f:write(__line or 'ok') else __f:write('err ' .. tostring(__err)) end\n"
        "  __f:write('\\n')\n"
        "  __f:close()\n"
        "end\n"
    )
    _focus_quiet += 1
    try:
        proc = subprocess.run(
            ["hyprctl", "eval", wrapper],
            capture_output=True,
            text=True,
            check=False,
        )
    finally:
        _focus_quiet -= 1
    text = result.read_text(encoding="utf-8").strip() if result.exists() else ""
    if not text.startswith("ok"):
        detail = text or proc.stderr.strip() or proc.stdout.strip() or "layout script failed"
        raise RuntimeError(detail)
    park = re.search(r"park=(\d+)", text)
    laptop_now = re.search(r"laptop=(\d+)", text)
    if park and int(park.group(1)) > 0 and laptop_now:
        print(
            "screenmirror: that desktop is on the virtual screen. "
            f"This laptop is showing desktop {laptop_now.group(1)}.",
            flush=True,
        )
    return text


def _drop_output(name: str) -> None:
    subprocess.run(
        ["hyprctl", "output", "remove", name],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    for _ in range(25):
        if virtual_monitor() is None:
            return
        time.sleep(0.04)


def release_virtual() -> None:
    """Give every desktop back to the laptop, then remove the virtual screen."""
    if virtual_monitor() is None:
        return
    saved = laptop_snapshot()
    try:
        run_layout("release", 0)
    except RuntimeError as exc:
        print(f"screenmirror: could not return desktops from the virtual screen ({exc}).", flush=True)
    if virtual_monitor() is not None:
        _drop_output(_virtual_output_name)
    settle_laptop(saved)


def virtual_layout_problem(wanted: int, width: int, height: int) -> str:
    """Why the virtual screen is not ready to cast this desktop, or an empty string.

    An extra empty desktop on that screen is not a failure. The picture is the
    active desktop, and rejecting it made the TV show the laptop instead.
    """
    virt = virtual_monitor()
    if virt is None:
        return "virtual screen is missing"
    active = int((virt.get("activeWorkspace") or {}).get("id") or 0)
    if active != wanted:
        return f"virtual screen is showing desktop {active}"
    if abs(float(virt.get("scale") or 0) - 1.0) >= 0.01:
        return f"virtual screen scale is {virt.get('scale')}"
    size = (int(virt.get("width") or 0), int(virt.get("height") or 0))
    if size != (width, height):
        return f"virtual screen is {size[0]}x{size[1]}"
    host = workspace_table().get(wanted, ("", 0))[0]
    if host != _virtual_output_name:
        return f"desktop {wanted} is on {host or 'no screen'}"
    return ""


def virtual_layout_ok(wanted: int, width: int, height: int) -> bool:
    return virtual_layout_problem(wanted, width, height) == ""


def focused_monitor_name() -> str:
    for mon in hypr_json("monitors"):
        if mon.get("focused"):
            return str(mon.get("name") or "")
    return ""


def _named_monitor(name: str, include_hidden: bool = False) -> dict | None:
    for mon in hypr_monitors(include_hidden):
        if mon.get("name") == name:
            return mon
    return None


def _create_virtual_output() -> None:
    global _virtual_output_name
    visible = {str(mon.get("name") or "") for mon in hypr_json("monitors")}
    for name in _VIRTUAL_CANDIDATES:
        hidden = _named_monitor(name, include_hidden=True)
        if hidden and not _usable_output(hidden):
            # Hyprland will not remove a mirror output, and it keeps the name.
            continue
        if name in visible and _usable_output(hidden):
            _virtual_output_name = name
            return
        subprocess.run(
            ["hyprctl", "output", "create", "headless", name],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        for _ in range(25):
            appeared = _named_monitor(name)
            if appeared and _usable_output(appeared):
                _virtual_output_name = name
                return
            time.sleep(0.04)
    raise RuntimeError("could not create the virtual screen")


def _apply_virtual_size(laptop: dict, width: int, height: int) -> None:
    configure_virtual(laptop, width, height)
    if virtual_needs_scale_fix():
        fresh = laptop_monitor()
        if fresh:
            configure_virtual(fresh, width, height)


def ensure_virtual_output(width: int, height: int) -> bool:
    """Make the virtual screen the requested size. Returns whether that size changed.

    The mode is changed in place. Recreating the screen would drop its desktop
    onto the laptop for a moment, and a fullscreen window would keep the old box.
    """
    laptop = laptop_monitor()
    if laptop is None:
        raise RuntimeError("no laptop screen")
    name = str(laptop.get("name") or "")
    if not _MONITOR_NAME.fullmatch(name):
        raise RuntimeError(f"unexpected monitor name {name!r}")
    existing = virtual_monitor()
    before = (
        (int(existing.get("width") or 0), int(existing.get("height") or 0)) if existing else (0, 0)
    )
    if existing is None:
        _create_virtual_output()
        time.sleep(0.15)
        laptop = laptop_monitor() or laptop
    _apply_virtual_size(laptop, width, height)
    if _wait_virtual_size(width, height):
        return before != (width, height)
    # The mode did not land. Rebuild the screen once, then wait again.
    release_virtual()
    laptop = laptop_monitor() or laptop
    _create_virtual_output()
    time.sleep(0.15)
    laptop = laptop_monitor() or laptop
    _apply_virtual_size(laptop, width, height)
    if not _wait_virtual_size(width, height):
        raise RuntimeError(f"virtual screen did not reach {width}x{height}")
    return True


def _wait_virtual_size(width: int, height: int) -> bool:
    deadline = time.time() + 1.2
    while time.time() < deadline:
        virt = virtual_monitor()
        if (
            virt
            and (int(virt.get("width") or 0), int(virt.get("height") or 0)) == (width, height)
            and abs(float(virt.get("scale") or 0) - 1.0) < 0.01
        ):
            return True
        time.sleep(0.05)
    return False


def _client_box(client: dict) -> tuple[int, int]:
    size = client.get("size") or [0, 0]
    try:
        return int(size[0]), int(size[1])
    except (TypeError, ValueError, IndexError):
        return 0, 0


def _fullscreen_targets(workspace: int) -> list[tuple[str, str, tuple[int, int]]]:
    try:
        clients = json.loads(subprocess.check_output(["hyprctl", "clients", "-j"], text=True))
    except Exception:
        return []
    if not isinstance(clients, list):
        return []
    found: list[tuple[str, str, tuple[int, int]]] = []
    for client in clients:
        try:
            ws = int((client.get("workspace") or {}).get("id") or 0)
            mode_id = int(client.get("fullscreen") or 0)
        except (TypeError, ValueError):
            continue
        if ws != workspace or mode_id == 0:
            continue
        address = str(client.get("address") or "")
        if not address:
            continue
        selector = address if address.startswith("address:") else f"address:{address}"
        mode = "maximized" if mode_id == 1 else "fullscreen"
        found.append((selector, mode, _client_box(client)))
    return found


def refit_fullscreen(workspace: int, width: int, height: int) -> None:
    """Size fullscreen windows to the screen they are on now.

    A mode change leaves a fullscreen window at its old box. Toggling
    fullscreen makes Hyprland fit it to the current screen.
    """
    for _attempt in range(2):
        targets = _fullscreen_targets(workspace)
        pending = [item for item in targets if item[2] != (width, height)]
        if not pending:
            return
        global _focus_quiet
        _focus_quiet += 1
        try:
            for selector, mode, _box in pending:
                hypr_dispatch(f'hl.dsp.window.fullscreen({{ window = "{selector}", action = "unset" }})')
                hypr_dispatch(
                    f'hl.dsp.window.fullscreen({{ window = "{selector}", mode = "{mode}", action = "set" }})'
                )
        finally:
            _focus_quiet -= 1
        time.sleep(0.12)


def _client_selector(client: dict) -> str:
    address = str(client.get("address") or "")
    if not address:
        return ""
    return address if address.startswith("address:") else f"address:{address}"


def snapshot_windows(workspace: int) -> list[dict]:
    """Remember each window as a fraction of the screen it is on now."""
    try:
        clients = json.loads(subprocess.check_output(["hyprctl", "clients", "-j"], text=True))
        mons = json.loads(subprocess.check_output(["hyprctl", "monitors", "-j"], text=True))
    except Exception:
        return []
    if not isinstance(clients, list) or not isinstance(mons, list):
        return []
    by_id = {mon.get("id"): mon for mon in mons}
    shots: list[dict] = []
    for client in clients:
        try:
            ws = int((client.get("workspace") or {}).get("id") or 0)
            mode_id = int(client.get("fullscreen") or 0)
        except (TypeError, ValueError):
            continue
        if ws != workspace:
            continue
        selector = _client_selector(client)
        mon = by_id.get(client.get("monitor"))
        if not selector or not mon:
            continue
        ow, oh = int(mon.get("width") or 0), int(mon.get("height") or 0)
        if ow < 1 or oh < 1:
            continue
        at = client.get("at") or [0, 0]
        box = _client_box(client)
        try:
            ax, ay = float(at[0]), float(at[1])
        except (TypeError, ValueError, IndexError):
            ax, ay = float(mon.get("x") or 0), float(mon.get("y") or 0)
        shots.append(
            {
                "selector": selector,
                "fullscreen": mode_id,
                "relx": (ax - float(mon.get("x") or 0)) / ow,
                "rely": (ay - float(mon.get("y") or 0)) / oh,
                "relw": box[0] / ow,
                "relh": box[1] / oh,
            }
        )
    return shots


def scale_windows(workspace: int, shots: list[dict], width: int, height: int) -> None:
    """Give every window the same share of the new screen it had of the old one."""
    if not shots or width < 1 or height < 1:
        return
    virt = virtual_monitor()
    if virt is None:
        return
    origin_x, origin_y = int(virt.get("x") or 0), int(virt.get("y") or 0)
    global _focus_quiet
    _focus_quiet += 1
    try:
        for shot in shots:
            if int(shot.get("fullscreen") or 0) != 0:
                continue
            new_w = max(1, round(float(shot["relw"]) * width))
            new_h = max(1, round(float(shot["relh"]) * height))
            new_x = origin_x + round(float(shot["relx"]) * width)
            new_y = origin_y + round(float(shot["rely"]) * height)
            selector = shot["selector"]
            hypr_dispatch(
                f'hl.dsp.window.resize({{ window = "{selector}", x = {new_w}, y = {new_h}, relative = false }})'
            )
            hypr_dispatch(
                f'hl.dsp.window.move({{ window = "{selector}", x = {new_x}, y = {new_y}, relative = false }})'
            )
    finally:
        _focus_quiet -= 1


def show_desktop(wanted: int, width: int, height: int) -> int:
    shots = snapshot_windows(wanted)
    resized = ensure_virtual_output(width, height)
    line = run_layout("show", wanted)
    problem = virtual_layout_problem(wanted, width, height)
    if problem.startswith("virtual screen is showing"):
        # A new virtual screen can restore its previous desktop a moment later.
        time.sleep(0.2)
        line = run_layout("show", wanted)
    for _ in range(8):
        problem = virtual_layout_problem(wanted, width, height)
        if not problem:
            break
        time.sleep(0.05)
    if problem:
        virt = virtual_monitor()
        active = int((virt.get("activeWorkspace") or {}).get("id") or 0) if virt else 0
        size_ok = bool(
            virt
            and (int(virt.get("width") or 0), int(virt.get("height") or 0)) == (width, height)
            and abs(float(virt.get("scale") or 0) - 1.0) < 0.01
        )
        if not (size_ok and active == wanted):
            raise RuntimeError(f"desktop {wanted} did not stay on the virtual screen ({problem}; {line})")
        print(f"screenmirror: desktop {wanted} is on the virtual screen ({problem}).", flush=True)
    if resized:
        scale_windows(wanted, shots, width, height)
        refit_fullscreen(wanted, width, height)
    if focused_monitor_name() == _virtual_output_name:
        run_layout("focus", 0)
    laptop = laptop_monitor()
    stay = int((laptop.get("activeWorkspace") or {}).get("id") or 0) if laptop else 0
    if stay and stay != wanted:
        focus_laptop_window(stay)
    # Placing the desktop is our action. A stale "user opened it" mark would
    # bring the desktop straight back onto the laptop.
    global _user_focus_monitor, _user_focus_workspace, _open_request
    if _open_request == wanted:
        _open_request = 0
    if _user_focus_monitor in _VIRTUAL_CANDIDATES and _user_focus_workspace == wanted:
        laptop = laptop_monitor()
        shown = int((laptop.get("activeWorkspace") or {}).get("id") or 0) if laptop else 0
        _user_focus_monitor = str(laptop.get("name") or "") if laptop else ""
        _user_focus_workspace = shown
    return wanted


def note_monitor_focus(line: str) -> None:
    """Record which screen the user just focused. `focusedmon>>eDP-1,4`."""
    global _user_focus_monitor, _user_focus_workspace
    global _open_request, _open_request_at, _laptop_ws_seen
    if _focus_quiet:
        return
    payload = line.split(">>", 1)[1]
    name, _, workspace = payload.partition(",")
    if not name:
        return
    ident = int(workspace) if workspace.isdigit() else 0
    if name in _VIRTUAL_CANDIDATES and ident > 0:
        if _laptop_ws_seen <= 0:
            laptop = laptop_monitor()
            if laptop:
                _laptop_ws_seen = int((laptop.get("activeWorkspace") or {}).get("id") or 0)
        _open_request = ident
        _open_request_at = time.time()
        _user_focus_monitor = name
        _user_focus_workspace = ident
        print(f"screenmirror: opening desktop {ident} from the virtual screen.", flush=True)
        return
    # The pointer stays on the laptop, so Hyprland focuses it again at once.
    # That bounce names the desktop the laptop was already showing.
    if _open_request and (time.time() - _open_request_at) < 0.5 and ident == _laptop_ws_seen:
        return
    _open_request = 0
    _user_focus_monitor = name
    _user_focus_workspace = ident
    if ident > 0:
        _laptop_ws_seen = ident
        if ident != _cast_workspace:
            hold_picture()


def note_workspace_change(line: str) -> None:
    """Freeze the picture when the laptop leaves the cast desktop.

    That change stays on this screen, so Hyprland does not send a monitor-focus
    event. The recorder would otherwise keep sending the new desktop.
    """
    if _focus_quiet:
        return
    payload = line.split(">>", 1)[1]
    if line.startswith("workspacev2>>"):
        ident_text, _, _name = payload.partition(",")
    else:
        ident_text = payload.strip()
    if not ident_text.lstrip("-").isdigit():
        return
    ident = int(ident_text)
    if ident <= 0 or ident == _cast_workspace or _cast_follow or _status_output in _VIRTUAL_CANDIDATES:
        return
    laptop = laptop_monitor()
    if laptop is None:
        return
    current = int((laptop.get("activeWorkspace") or {}).get("id") or 0)
    if current != ident:
        return
    hold_picture()


def hold_picture() -> None:
    """Keep the last JPEG. The next frames would be the laptop's new desktop."""
    global _hold_picture
    if _hold_picture or _cast_follow or _status_output in _VIRTUAL_CANDIDATES:
        return
    _hold_picture = True
    _reload.set()
    proc = _proc
    if proc is not None and proc.poll() is None:
        proc.send_signal(signal.SIGINT)
    print("screenmirror: holding the picture while the desktop moves.", flush=True)


def user_opened_cast_desktop(chosen: int) -> bool:
    """True when the user just selected the cast desktop on the virtual screen."""
    if _open_request == chosen or (
        _user_focus_monitor in _VIRTUAL_CANDIDATES and _user_focus_workspace == chosen
    ):
        return True
    if focused_monitor_name() not in _VIRTUAL_CANDIDATES:
        return False
    virt = virtual_monitor()
    if not virt:
        return False
    return int((virt.get("activeWorkspace") or {}).get("id") or 0) == chosen


def hand_to_laptop(chosen: int) -> str:
    """Show the cast desktop on the laptop, and drop the virtual screen."""
    global _hold_laptop_workspace
    laptop = laptop_monitor()
    if laptop is None:
        raise RuntimeError("no laptop screen")
    laptop_name = str(laptop.get("name") or "eDP-1")
    host, _windows = workspace_table().get(chosen, ("", 0))
    _hold_laptop_workspace = chosen
    if host and host != laptop_name:
        run_layout("borrow", chosen)
    if virtual_monitor() is not None:
        release_virtual()
    laptop = laptop_monitor() or laptop
    now = int((laptop.get("activeWorkspace") or {}).get("id") or 0)
    if now != chosen:
        focus_workspace(chosen)
    global _user_focus_monitor, _user_focus_workspace
    global _open_request, _laptop_ws_seen
    _open_request = 0
    _laptop_ws_seen = chosen
    _user_focus_monitor = laptop_name
    _user_focus_workspace = chosen
    print(f"screenmirror: showing desktop {chosen} on the laptop.", flush=True)
    return str(laptop.get("name") or laptop_name)


def plan_capture() -> tuple[str, int, int, bool, int]:
    """Return output name, size, whether it is the virtual screen, and desktop id.

    Follow Screen captures the laptop and does not move desktops.
    A numbered desktop stays on the laptop while that desktop is showing there,
    and moves to the virtual screen when the laptop switches away.
    """
    global _cast_workspace, _cast_virtual, _cast_follow, _cast_width, _cast_height
    global _hold_laptop_workspace
    chosen, width, height = read_cast()
    _cast_width, _cast_height = width, height
    laptop = laptop_monitor()
    if laptop is None:
        _cast_follow, _cast_virtual, _cast_workspace = True, False, 1
        return "eDP-1", width, height, False, 1
    laptop_ws = int((laptop.get("activeWorkspace") or {}).get("id") or 1)
    laptop_name = str(laptop.get("name") or "eDP-1")
    if chosen is None:
        _hold_laptop_workspace = 0
        _cast_follow, _cast_virtual = True, False
        if virtual_monitor() is not None:
            release_virtual()
            laptop = laptop_monitor() or laptop
            laptop_ws = int((laptop.get("activeWorkspace") or {}).get("id") or laptop_ws)
            laptop_name = str(laptop.get("name") or laptop_name)
        _cast_workspace = laptop_ws
        return laptop_name, width, height, False, laptop_ws
    if laptop_ws == chosen or user_opened_cast_desktop(chosen):
        laptop_name = hand_to_laptop(chosen)
        native = output_size(laptop_name)
        if native:
            _cast_width, _cast_height = native
        _cast_follow, _cast_virtual, _cast_workspace = False, False, chosen
        return laptop_name, _cast_width, _cast_height, False, chosen
    _hold_laptop_workspace = 0
    actual = show_desktop(chosen, width, height)
    _cast_follow, _cast_virtual, _cast_workspace = False, True, actual
    return _virtual_output_name, width, height, True, actual


_capture_log = None


_vaapi_checked = False
_vaapi_ok = False


def vaapi_available(output: str) -> bool:
    global _vaapi_checked, _vaapi_ok
    if _vaapi_checked:
        return _vaapi_ok
    _vaapi_checked = True
    if not os.path.exists(VAAPI_DEVICE):
        return False
    probe = RUNTIME / "vaapi-probe.mjpg"
    probe.unlink(missing_ok=True)
    cmd = [
        "wf-recorder",
        "-o",
        output,
        "-d",
        VAAPI_DEVICE,
        "-c",
        "mjpeg_vaapi",
        "-r",
        "5",
        "-m",
        "mjpeg",
        "-f",
        str(probe),
        "-D",
    ]
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        _vaapi_ok = False
        probe.unlink(missing_ok=True)
        return False
    # The probe file stays empty until wf-recorder exits and flushes it.
    time.sleep(0.45)
    if proc.poll() is None:
        proc.send_signal(signal.SIGINT)
    try:
        proc.wait(timeout=1.0)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=0.6)
    _vaapi_ok = probe.exists() and probe.stat().st_size > 1000
    probe.unlink(missing_ok=True)
    if _vaapi_ok:
        print("screenmirror: encoding with the GPU", flush=True)
    else:
        print("screenmirror: GPU encode is unavailable, using the CPU", flush=True)
    return _vaapi_ok


def encode_size(output: str, width: int, height: int) -> tuple[int, int]:
    """Do not enlarge this laptop's own screen. That upscale was soft and slow.

    A virtual desktop is created at the requested size, so it stays 1:1.
    """
    native = output_size(output)
    if output not in _VIRTUAL_CANDIDATES and native and (width > native[0] or height > native[1]):
        return native
    return width, height


def start_capture(output: str) -> subprocess.Popen:
    global _capture_log, WIDTH, HEIGHT
    width, height = encode_size(output, int(WIDTH), int(HEIGHT))
    WIDTH, HEIGHT = str(width), str(height)
    if FIFO.exists() or FIFO.is_symlink():
        FIFO.unlink()
    os.mkfifo(FIFO, 0o600)
    if _capture_log is not None:
        _capture_log.close()
    log = open(RUNTIME / "capture.log", "w")
    _capture_log = log
    fps = stream_fps(width, height)
    native = output_size(output)
    use_vaapi = vaapi_available(output)
    if use_vaapi:
        cmd = [
            "wf-recorder",
            "-o",
            output,
            "-d",
            VAAPI_DEVICE,
            "-c",
            "mjpeg_vaapi",
            "-r",
            fps,
            "-p",
            f"global_quality={vaapi_quality(width, height)}",
            "-p",
            "async_depth=1",
            "-m",
            "mjpeg",
            "-f",
            str(FIFO),
            "-D",
        ]
        if native and native != (width, height):
            cmd[cmd.index("-m"):cmd.index("-m")] = [
                "-F",
                f"scale_vaapi=w={width}:h={height}:format=nv12",
            ]
    else:
        cmd = [
            "wf-recorder",
            "-o",
            output,
            "-c",
            "mjpeg",
            "-r",
            fps,
            "-x",
            "yuvj420p",
            "-p",
            f"qscale={QSCALE}",
            "-p",
            "qmin=2",
            "-p",
            "qmax=6",
            "-m",
            "mjpeg",
            "-f",
            str(FIFO),
            "-D",
        ]
        if native and native != (width, height):
            cmd[cmd.index("-m"):cmd.index("-m")] = [
                "-F",
                f"scale={width}:{height}:flags=bilinear",
            ]
    return subprocess.Popen(
        cmd,
        stdout=subprocess.DEVNULL,
        stderr=log,
        env=os.environ.copy(),
    )


def reader_loop() -> None:
    global _frame, _frame_id
    while not _stop.is_set():
        if _reload.is_set() or _proc is None:
            _reader_idle.set()
            while (_reload.is_set() or _proc is None) and not _stop.is_set():
                time.sleep(0.02)
            _reader_idle.clear()
            continue
        proc = _proc
        # A blocking open waits forever for a writer. A reload has to be able
        # to close this and open the new stream without that wait.
        try:
            fd = os.open(FIFO, os.O_RDONLY | os.O_NONBLOCK)
        except OSError:
            time.sleep(0.05)
            continue
        fh = os.fdopen(fd, "rb", buffering=0)
        buf = b""
        try:
            while not _stop.is_set() and not _reload.is_set():
                try:
                    chunk = fh.read(65536)
                except BlockingIOError:
                    time.sleep(0.01)
                    continue
                if not chunk:
                    if _reload.is_set() or proc.poll() is not None:
                        break
                    time.sleep(0.01)
                    continue
                buf += chunk
                if len(buf) > 8_000_000:
                    buf = buf[-2_000_000:]
                while True:
                    start = buf.find(b"\xff\xd8")
                    if start < 0:
                        buf = buf[-1:]
                        break
                    end = buf.find(b"\xff\xd9", start + 2)
                    if end < 0:
                        buf = buf[start:]
                        break
                    jpeg = buf[start : end + 2]
                    buf = buf[end + 2 :]
                    if _hold_picture or _reload.is_set():
                        continue
                    with _cond:
                        _frame = jpeg
                        _frame_id += 1
                        first = _frame_id == 1
                        _cond.notify_all()
                    if first and _status_ip:
                        write_status(_status_ip, _status_output, _listening, ready=True)
        finally:
            fh.close()


def log_access(addr: str, line: str) -> None:
    stamp = time.strftime("%H:%M:%S")
    msg = f"{stamp} {addr} {line}\n"
    sys.stderr.write(msg)
    sys.stderr.flush()
    with ACCESS_LOG.open("a") as fh:
        fh.write(msg)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    close_connection = True

    def log_message(self, fmt: str, *args) -> None:
        log_access(self.address_string(), fmt % args)

    def _send(self, code: int, ctype: str, body: bytes) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("Pragma", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def _old_tv(self) -> bool:
        """TVs with old browsers tear a multipart stream and paint frames on top of each other."""
        agent = (self.headers.get("User-Agent") or "").lower()
        markers = (
            "viera",
            "panasonic",
            "netfront",
            "hbbtv",
            "smarttv",
            "smart-tv",
            "bravia",
            "tizen",
            "webos",
            "netcast",
            "aquos",
        )
        return any(marker in agent for marker in markers)

    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html", "/index.htm"):
            page = POLL_HTML if self._old_tv() else HTML
            self._send(200, "text/html", page.encode("ascii", "replace"))
            return
        if path == "/poll":
            self._send(200, "text/html", POLL_HTML.encode("ascii", "replace"))
            return
        if path in ("/stream.mjpg", "/live.mjpg"):
            self._stream()
            return
        if path in ("/frame.jpg", "/frame.jpeg", "/desktop.jpg"):
            with _lock:
                frame = _frame
            if not frame:
                self._send(503, "text/plain", b"starting\n")
                return
            self._send(200, "image/jpeg", frame)
            return
        if path in ("/health", "/ok"):
            body = b"ok\n" if _frame_id else b"starting\n"
            self._send(200 if _frame_id else 503, "text/plain", body)
            return
        self._send(404, "text/plain", b"not found\n")

    def _stream(self) -> None:
        """Push the newest JPEG as soon as it is encoded. Skip any the TV has not caught up to."""
        try:
            self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass
        self.send_response(200)
        self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("Pragma", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        last = 0
        try:
            while not _stop.is_set():
                with _cond:
                    if _frame_id == last:
                        _cond.wait(timeout=0.5)
                    frame = _frame
                    fid = _frame_id
                if not frame or fid == last:
                    continue
                last = fid
                packet = (
                    b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: "
                    + str(len(frame)).encode()
                    + b"\r\n\r\n"
                    + frame
                    + b"\r\n"
                )
                self.wfile.write(packet)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, TimeoutError, OSError):
            return


def write_status(ip: str, output: str, listening: bool, ready: bool | None = None) -> None:
    urls = [f"http://{ip}:{port}/" for port in PORTS]
    if ready is None:
        ready = _frame_id > 0
    payload = (
        json.dumps(
            {
                "listening": listening,
                "ready": ready,
                "ip": ip,
                "output": output,
                "workspace": _cast_workspace,
                "virtual": _cast_virtual,
                "follow": _cast_follow,
                "width": _cast_width,
                "height": _cast_height,
                "urls": urls,
                "primary": urls[0],
            },
            indent=2,
        )
        + "\n"
    )
    with _status_lock:
        URL_FILE.write_text(urls[0] + "\n")
        STATUS_FILE.write_text(payload)


def stop_capture() -> None:
    global _proc
    proc = _proc
    _proc = None
    if not proc:
        return
    if proc.poll() is None:
        proc.send_signal(signal.SIGINT)
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
            try:
                proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                pass
    else:
        try:
            proc.wait(timeout=0.2)
        except subprocess.TimeoutExpired:
            pass


def capture_plan() -> tuple[str, int, int, bool, int]:
    global _layout_failures, _cast_follow, _cast_virtual, _cast_workspace, _cast_width, _cast_height
    try:
        planned = plan_capture()
        _layout_failures = 0
        return planned
    except Exception as exc:
        _layout_failures += 1
        print(f"screenmirror: desktop layout failed ({exc}).", flush=True)
        chosen, width, height = read_cast()
        _cast_width, _cast_height = width, height
        if chosen is not None:
            # Streaming the laptop here is what flashed the other desktop on the TV.
            _cast_follow, _cast_virtual, _cast_workspace = False, True, chosen
            if virtual_layout_ok(chosen, width, height):
                return _virtual_output_name, width, height, True, chosen
            print("screenmirror: keeping the last picture until that desktop is ready.", flush=True)
            return None
        laptop = laptop_monitor()
        output = str(laptop["name"]) if laptop else default_output()
        ws = int((laptop.get("activeWorkspace") or {}).get("id") or 1) if laptop else 1
        _cast_follow, _cast_virtual, _cast_workspace = True, False, ws
        return output, width, height, False, ws


def encoder_matches(output: str, width: int, height: int) -> bool:
    size = encode_size(output, width, height)
    return (
        _proc is not None
        and _proc.poll() is None
        and _status_output == output
        and (int(WIDTH), int(HEIGHT)) == size
    )


def _cast_message(output: str, width: int, height: int, virtual: bool, workspace: int) -> str:
    if _cast_follow:
        return f"Casting this screen from {output} at {width}x{height}."
    where = "a virtual screen" if virtual else "this screen"
    return f"Casting desktop {workspace} from {output} at {width}x{height} on {where}."


def begin_capture(planned: tuple[str, int, int, bool, int] | None = None) -> None:
    global _proc, _status_output, WIDTH, HEIGHT, _frame, _frame_id
    output, width, height, virtual, workspace = planned if planned is not None else capture_plan()
    message = _cast_message(output, width, height, virtual, workspace)
    if planned is not None and encoder_matches(output, width, height):
        _status_output = output
        print(message, flush=True)
        return
    WIDTH, HEIGHT = str(width), str(height)
    _status_output = output
    with _cond:
        _frame = b""
        _frame_id = 0
        _cond.notify_all()
    _proc = start_capture(output)
    print(message, flush=True)


def _viewing_on_laptop(chosen: int | None) -> bool:
    if chosen is None:
        return True
    laptop = laptop_monitor()
    if laptop is None:
        return False
    laptop_ws = int((laptop.get("activeWorkspace") or {}).get("id") or 0)
    return laptop_ws == chosen or user_opened_cast_desktop(chosen)


def _capture_output_changes(chosen: int | None, width: int, height: int) -> bool:
    """True when the next layout removes or replaces the screen being recorded."""
    virt = virtual_monitor()
    if _viewing_on_laptop(chosen):
        return virt is not None or _status_output in _VIRTUAL_CANDIDATES
    if virt is None or _status_output not in _VIRTUAL_CANDIDATES:
        return True
    return (int(virt.get("width") or 0), int(virt.get("height") or 0)) != (width, height)


def _pause_capture() -> None:
    _reload.set()
    stop_capture()
    if not _reader_idle.wait(timeout=2):
        print("screenmirror: capture reader did not pause", flush=True)


def _reload_capture_locked() -> None:
    global _hold_picture, _hold_laptop_workspace
    saved_laptop = laptop_snapshot()
    chosen, width, height = read_cast()
    # Stop the recorder before the output it is using disappears. Removing
    # that output first left wf-recorder stuck and the reader waiting on it.
    force_restart = virtual_needs_scale_fix()
    if force_restart or _hold_picture or _capture_output_changes(chosen, width, height):
        _pause_capture()
    planned = capture_plan()
    if planned is None:
        settle_laptop(saved_laptop)
        if _layout_failures >= 3:
            _hold_picture = False
            _reload.clear()
        return
    output, width, height, _virtual, _workspace = planned
    try:
        if (
            not force_restart
            and _proc is not None
            and _proc.poll() is None
            and encoder_matches(output, width, height)
        ):
            begin_capture(planned)
            if _status_ip:
                write_status(_status_ip, _status_output, _listening, ready=True)
            return
        if not _reload.is_set():
            _pause_capture()
        begin_capture(planned)
        if _status_ip:
            write_status(_status_ip, _status_output, _listening, ready=False)
    finally:
        _hold_picture = False
        _reload.clear()
        settle_laptop(saved_laptop)
        _hold_laptop_workspace = 0


def reload_capture() -> None:
    with _layout_lock:
        _reload_capture_locked()


def layout_issue() -> str:
    """Return why the screens do not match the cast choice, or an empty string."""
    chosen, width, height = read_cast()
    # Read the event first. A monitor query often runs after the focus has
    # already been pulled back, and that pull is what hid the user's selection.
    opened = chosen is not None and (
        _open_request == chosen
        or (_user_focus_monitor in _VIRTUAL_CANDIDATES and _user_focus_workspace == chosen)
    )
    focus = focused_monitor_name()
    if chosen is not None and (opened or focus in _VIRTUAL_CANDIDATES):
        return "borrow"
    if chosen is None:
        if virtual_monitor() is not None:
            return "follow"
        if focus in _VIRTUAL_CANDIDATES:
            return "focus"
        return ""
    laptop = laptop_monitor()
    laptop_ws = int((laptop.get("activeWorkspace") or {}).get("id") or 0) if laptop else 0
    laptop_name = str(laptop.get("name") or "") if laptop else ""
    if laptop_ws > 0 and not _open_request:
        global _laptop_ws_seen
        _laptop_ws_seen = laptop_ws
    if laptop_ws == chosen:
        host, _windows = workspace_table().get(chosen, ("", 0))
        if host != laptop_name or virtual_monitor() is not None or _status_output in _VIRTUAL_CANDIDATES:
            return "borrow"
        return ""
    if not virtual_layout_ok(chosen, width, height):
        return "place"
    return ""


def _reassert_locked() -> None:
    global _layout_failures
    if _layout_failures >= 3:
        return
    issue = layout_issue()
    if not issue:
        return
    if issue == "focus":
        try:
            run_layout("focus", 0)
        except RuntimeError as exc:
            _layout_failures += 1
            print(f"screenmirror: could not return to the laptop screen ({exc}).", flush=True)
        return
    _reload_capture_locked()


def hypr_event_socket() -> Path | None:
    base = os.environ.get("XDG_RUNTIME_DIR")
    if not base:
        return None
    signature = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE")
    if signature:
        direct = Path(base) / "hypr" / signature / ".socket2.sock"
        if direct.exists():
            return direct
    root = Path(base) / "hypr"
    if not root.is_dir():
        return None
    found = sorted(root.glob("*/.socket2.sock"))
    return found[-1] if found else None


_LAYOUT_EVENTS = (
    "workspace>>",
    "workspacev2>>",
    "focusedmon>>",
    "moveworkspace>>",
    "moveworkspacev2>>",
    "createworkspace>>",
    "createworkspacev2>>",
    "destroyworkspace>>",
    "destroyworkspacev2>>",
    "monitoradded>>",
    "monitorremoved>>",
    "configreloaded>>",
)


def watch_hypr_events() -> None:
    """Notice desktop and focus changes so a numbered cast does not drift."""
    while not _stop.is_set():
        path = hypr_event_socket()
        if path is None:
            if _stop.wait(1):
                return
            continue
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
                sock.connect(str(path))
                sock.settimeout(0.5)
                buf = b""
                while not _stop.is_set():
                    try:
                        chunk = sock.recv(8192)
                    except TimeoutError:
                        continue
                    except OSError:
                        break
                    if not chunk:
                        break
                    buf += chunk
                    while b"\n" in buf:
                        raw, buf = buf.split(b"\n", 1)
                        line = raw.decode("utf-8", "replace")
                        if line.startswith(("focusedmon>>", "focusedmonv2>>")):
                            note_monitor_focus(line)
                        elif line.startswith(("workspace>>", "workspacev2>>")):
                            note_workspace_change(line)
                        if line.startswith(_LAYOUT_EVENTS):
                            _desktop_dirty.set()
        except OSError:
            if _stop.wait(0.5):
                return


def watch_cast() -> None:
    global _layout_failures
    last = CAST_FILE.stat().st_mtime_ns if CAST_FILE.exists() else 0
    ticks = 0
    while not _stop.is_set():
        signaled = _desktop_dirty.wait(0.12)
        if signaled:
            time.sleep(0.05)
        _desktop_dirty.clear()
        if _stop.is_set():
            return
        ticks += 1
        try:
            current = CAST_FILE.stat().st_mtime_ns if CAST_FILE.exists() else 0
        except OSError:
            current = 0
        changed = current != last
        if changed:
            last = current
        # A shell restart can put the virtual screen back at scale 2.
        scale = ticks % 8 == 0 and virtual_needs_scale_fix()
        periodic = ticks % 8 == 0
        dead = _proc is not None and _proc.poll() is not None and _layout_failures < 3
        if not (changed or signaled or scale or periodic or _hold_picture or dead):
            continue
        with _layout_lock:
            if _stop.is_set():
                return
            if changed or scale:
                _layout_failures = 0
                _reload_capture_locked()
            elif _hold_picture or dead:
                _reload_capture_locked()
            else:
                _reassert_locked()


def main() -> int:
    global _status_ip, _status_output, _listening
    RUNTIME.mkdir(mode=0o700, exist_ok=True)
    ACCESS_LOG.touch()
    ip = lan_ip()
    _status_ip = ip
    saved_laptop = laptop_snapshot()
    begin_capture()
    # Adding or removing the virtual screen can land the laptop on an older
    # desktop a moment later. Put it back, then check once more after that settles.
    settle_laptop(saved_laptop)
    time.sleep(0.2)
    settle_laptop(saved_laptop)
    _status_output = _status_output or default_output()
    write_status(ip, _status_output, False, ready=False)
    threading.Thread(target=reader_loop, daemon=True).start()
    threading.Thread(target=watch_cast, daemon=True).start()
    threading.Thread(target=watch_hypr_events, daemon=True).start()

    deadline = time.time() + 8
    while time.time() < deadline and _frame_id == 0 and not _stop.is_set():
        time.sleep(0.1)

    for port in PORTS:
        httpd = ThreadingHTTPServer((HOST, port), Handler)
        httpd.daemon_threads = True
        _servers.append(httpd)
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        print(f"Listening on http://{ip}:{port}/", flush=True)

    _listening = True
    write_status(ip, _status_output, True)
    print(f"Primary URL: http://{ip}:{PORTS[0]}/", flush=True)

    def shutdown(*_args) -> None:
        _stop.set()
        for httpd in _servers:
            httpd.shutdown()

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    try:
        while not _stop.is_set():
            time.sleep(0.5)
    finally:
        _stop.set()
        _desktop_dirty.set()
        _reload.clear()
        with _layout_lock:
            stop_capture()
            try:
                release_virtual()
            except Exception as exc:
                print(f"screenmirror: could not close the virtual screen ({exc}).", flush=True)
        for httpd in _servers:
            httpd.server_close()
        for path in (URL_FILE, STATUS_FILE, FIFO):
            try:
                path.unlink()
            except FileNotFoundError:
                pass
    return 0


if __name__ == "__main__":
    sys.exit(main())

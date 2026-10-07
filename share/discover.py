#!/usr/bin/env python3
"""List LAN receivers and which of them can take a desktop picture."""

from __future__ import annotations

import json
import re
import subprocess
import sys
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

SPEAKERS = (
    "nest mini",
    "nest audio",
    "chromecast audio",
    "home mini",
    "homepod",
    "audioaccessory",
    "google home",
    "google nest mini",
)

SERVICE_NAMES = {
    "_airplay._tcp": "AirPlay",
    "_googlecast._tcp": "Chromecast",
    "_display._tcp": "Miracast",
    "_androidtvremote2._tcp": "Android TV Remote",
    "_amzn-wplay._tcp": "Fire TV",
    "Amazon Fire TV": "Fire TV",
}

ID_PREFIX = {
    "Chromecast": "Chromecast",
    "AirPlay": "AirPlay",
    "Miracast": "Miracast",
    "Android TV Remote": "AndroidTV",
    "Fire TV": "FireTV",
    "DIAL": "DIAL",
}


def unescape(text: str) -> str:
    """Undo avahi-browse escapes. A space is the decimal sequence \\032."""
    raw = bytearray()
    i = 0
    while i < len(text):
        if text[i] == "\\" and i + 1 < len(text):
            nxt = text[i + 1]
            if nxt in "\\.":
                raw.extend(nxt.encode("utf-8"))
                i += 2
                continue
            digits = text[i + 1:i + 4]
            if len(digits) == 3 and digits.isdigit():
                value = int(digits, 10)
                if value <= 255:
                    raw.append(value)
                    i += 4
                    continue
        raw.extend(text[i].encode("utf-8"))
        i += 1
    return raw.decode("utf-8", "replace")


def txt_map(raw: str) -> dict[str, str]:
    found: dict[str, str] = {}
    for part in re.findall(r'"([^"]*)"', raw):
        if "=" in part:
            key, value = part.split("=", 1)
            found[key] = unescape(value)
    return found


def looks_like_speaker(model: str, name: str) -> bool:
    folded = f"{model} {name}".lower()
    if "hub" in folded:
        return False
    if "group" in folded:
        return True
    return any(word in folded for word in SPEAKERS)


def _blank(address: str) -> dict:
    return {
        "address": address,
        "name": "",
        "model": "",
        "_name_rank": -1,
        "_model_rank": -1,
        "protocols": [],
    }


def _prefer(device: dict, field: str, rank_field: str, value: str, rank: int) -> None:
    if not value:
        return
    if rank >= device[rank_field]:
        device[field] = value
        device[rank_field] = rank


def _add_protocol(device: dict, name: str, port: int, *, video: bool, can_mirror: bool) -> None:
    for item in device["protocols"]:
        if item["name"] == name and item["port"] == port:
            item["video"] = item["video"] or video
            item["canMirror"] = item["canMirror"] or can_mirror
            return
    device["protocols"].append(
        {"name": name, "port": port, "video": video, "canMirror": can_mirror}
    )


def note_for(names: list[str], *, video: bool, can_mirror: bool) -> str:
    if can_mirror:
        return ""
    if "Fire TV" in names:
        if "DIAL" in names:
            return (
                "Fire TV uses Amazon messaging and DIAL. "
                "DIAL can open Netflix. It cannot show this desktop."
            )
        return "Fire TV uses Amazon messaging. It cannot show this desktop."
    if "Android TV Remote" in names:
        return "Android TV Remote sends keys after pairing. It cannot show this desktop."
    if "AirPlay" in names:
        return "AirPlay is visible. This computer has no AirPlay sender."
    if "Miracast" in names:
        return "Miracast needs Wi-Fi Direct. This computer does not send it."
    if "Chromecast" in names and not video:
        return "This is a speaker, so it cannot show the screen."
    return ""


def parse_browse(text: str) -> list[dict]:
    devices: dict[str, dict] = {}
    for line in text.splitlines():
        if not line.startswith("="):
            continue
        parts = line.split(";")
        if len(parts) < 9:
            continue
        protocol_name = SERVICE_NAMES.get(parts[4])
        if protocol_name is None or parts[2] != "IPv4":
            continue
        address = parts[7]
        if not address or ":" in address:
            continue
        try:
            port = int(parts[8])
        except ValueError:
            continue
        fields = txt_map(";".join(parts[9:]))
        model = fields.get("md") or fields.get("model") or fields.get("am") or ""
        friendly = fields.get("fn") or fields.get("n") or fields.get("name") or ""
        instance = unescape(parts[3])
        device = devices.setdefault(address, _blank(address))
        rank = 3 if protocol_name == "Chromecast" and friendly else 2 if friendly else 1
        _prefer(device, "name", "_name_rank", friendly or instance, rank)
        _prefer(device, "model", "_model_rank", model, 2 if protocol_name == "Chromecast" else 1)

        video = False
        can_mirror = False
        if protocol_name == "Chromecast":
            ca_raw = fields.get("ca")
            try:
                ca = int(ca_raw) if ca_raw else None
            except ValueError:
                ca = None
            speaker = looks_like_speaker(model, friendly or instance)
            if ca is None:
                video = not speaker
            else:
                video = bool(ca & 1) and not speaker
            can_mirror = video
        elif protocol_name == "Miracast":
            video = True
        elif protocol_name in ("Fire TV", "Android TV Remote"):
            video = True
        elif protocol_name == "AirPlay":
            video = not looks_like_speaker(model, friendly or instance)
        _add_protocol(device, protocol_name, port, video=video, can_mirror=can_mirror)
    return list(devices.values())


def _finish(device: dict) -> dict:
    protocols = device["protocols"]
    mirror = next((item for item in protocols if item["canMirror"]), None)
    primary = mirror or protocols[0]
    names = [item["name"] for item in protocols]
    video = any(item["video"] for item in protocols)
    can_mirror = mirror is not None
    prefix = ID_PREFIX.get(primary["name"], primary["name"])
    return {
        "id": f"{prefix}:{device['address']}",
        "name": device["name"] or device["address"],
        "protocol": primary["name"],
        "protocols": protocols,
        "address": device["address"],
        "port": primary["port"],
        "model": device["model"],
        "video": video,
        "canMirror": can_mirror,
        "note": note_for(names, video=video, can_mirror=can_mirror),
    }


def probe_dial(ip: str, port: int = 8009) -> bool:
    """True when this host answers the DIAL Netflix app record."""
    url = f"http://{ip}:{port}/apps/Netflix"
    try:
        with urllib.request.urlopen(url, timeout=0.8) as response:
            return response.status == 200
    except urllib.error.HTTPError:
        return False
    except Exception:
        return False


def build(text: str, probe=None) -> dict:
    devices = parse_browse(text)
    if probe is not None:
        fire = [device for device in devices if any(item["name"] == "Fire TV" for item in device["protocols"])]
        if fire:
            with ThreadPoolExecutor(max_workers=min(8, len(fire))) as pool:
                found = list(pool.map(lambda device: probe(device["address"]), fire))
            for device, dial in zip(fire, found):
                if dial:
                    _add_protocol(device, "DIAL", 8009, video=True, can_mirror=False)
    receivers = [_finish(device) for device in devices if device["protocols"]]
    receivers.sort(key=lambda item: (not item["canMirror"], item["name"].lower()))
    return {"receivers": receivers}


def main() -> int:
    try:
        proc = subprocess.run(
            ["avahi-browse", "-arpkt"],
            text=True,
            capture_output=True,
            timeout=6,
        )
        text = proc.stdout or ""
    except FileNotFoundError:
        json.dump({"receivers": [], "error": "Install avahi to look for receivers."}, sys.stdout)
        sys.stdout.write("\n")
        return 0
    except subprocess.TimeoutExpired as exc:
        text = exc.stdout or ""
        if isinstance(text, bytes):
            text = text.decode("utf-8", "replace")
    json.dump(build(text, probe_dial), sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

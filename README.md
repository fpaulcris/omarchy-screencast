# Screen Cast

Cast an Omarchy desktop to a TV or phone browser on the same Wi-Fi. The other device opens an HTTP address and shows a live picture of the screen.

This is a browser address, so it will not show up in the TV's screen-cast menu. It is the path that works when Miracast or Wi-Fi Direct is unavailable.

Supports Omarchy 4.0.0 and later with the Quattro shell.

The TV or phone has to be on the same Wi-Fi as this computer.

## Install

`omarchy plugin add` clones this repository and can enable the shell plugin. It does not install the streamer. Run `install.sh` after add, and again after an update if you want the desktop launcher and user service refreshed:

```bash
omarchy plugin add https://github.com/fpaulcris/omarchy-screencast.git --enable
bash ~/.config/omarchy/plugins/fpaulcris.screenmirror/install.sh
```

Enabling the plugin places the Screen Cast button on the right side of the bar. Left click opens the panel. Right click starts or stops. Middle click refreshes.

## What you need

- `python3` (standard library only)
- `wf-recorder` (`omarchy pkg add wf-recorder` if it is missing)
- `qrencode` is optional. The window still shows the address without a QR code.
- `foot`, which the launcher uses for the status window
- `ffmpeg`, which builds the H.264 stream a Chromecast plays
- `avahi`, which the panel uses to list receivers on this Wi-Fi

The stream listens on TCP 8080, 8000, and 8090, on every interface, for a private LAN. This plugin does not change your firewall. If the TV browser stays blank, allow those ports from your LAN (for example `192.168.0.0/16`, `10.0.0.0/8`, and `172.16.0.0/12`) and do not expose them to the internet.

An optional Hyprland rule keeps the status window floating:

```lua
o.window({ class = "screenmirror" }, { float = true, center = true, size = { 780, 720 } })
```

`install.sh` does not edit Hyprland, sudoers, or the firewall.

## Use

- App launcher: Screen Cast. Opening it again focuses the window that is already open.
- Terminal: `screencast` shows the browser address. Press `q` to stop. A second copy refuses to start and does not stop the first one.
- Background: `screencast start` / `screencast stop`
- `screencast receivers` lists devices. `screencast mirror <id>` starts sending the picture to a Chromecast and returns while the TV is still connecting. `screencast mirror status` reports starting, live, or failed. `screencast mirror stop` returns that screen to what it was doing.
- Desktop and size: Follow Screen sends this laptop's screen. A numbered desktop stays on the laptop while you are looking at it, and moves to its own virtual screen when you switch away, so the picture keeps going. Sizes are 1280×720, 1920×1080, 2560×1440, and 3840×2160. 4K applies on the virtual screen. Windows on that desktop keep the same share of the screen when the size changes.
- The panel has two modes. Browser is this computer's address. Find Devices lists receivers on this Wi-Fi. A Chromecast, Nest Hub, or Android TV that speaks Cast can take the picture: select it and the desktop is sent as H.264, with the sound that is playing through this computer's speakers. The computer keeps playing that sound too. Fire TV answers DIAL and Amazon's own messaging, which cannot take the desktop. AirPlay and Miracast are listed when present; this computer does not send either.
- Address: `screencast url`, `screencast copy`, or the QR code button
- Machine status: `screencast status --json`

On the TV, open the internet browser and go to the address on screen. The service is not started at login.

## Remove

```bash
bash ~/.config/omarchy/plugins/fpaulcris.screenmirror/install.sh --uninstall
omarchy plugin remove fpaulcris.screenmirror
```

`install.sh --uninstall` removes the command link, the user service, the launcher, and the icon files it wrote, and only when they still match what it installed. `omarchy plugin remove` removes the plugin checkout. Neither command changes the firewall or Hyprland.

## Layout

The shell plugin (bar button, panel, and status service) watches the `screenmirror` command. `systemd --user` runs `share/server.py`, so the picture keeps going if the shell restarts. The panel keeps these states separate: not installed, stopped, starting, live, and failed.

## Support

Questions and bugs go to the [GitHub issues](https://github.com/fpaulcris/omarchy-screencast/issues) for this repository. Report a suspected compromise through a GitHub private security advisory on that repository. The plugin runs unsandboxed in your session. A marketplace listing check is not a security audit.

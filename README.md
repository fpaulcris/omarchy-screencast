# ScreenMirror

Mirror an Omarchy desktop to a TV or phone browser on the same Wi-Fi. The other device opens an HTTP address and shows a live picture of the screen.

This is a browser address, so it will not show up in the TV's screen-cast menu. It is the path that works when Miracast or Wi-Fi Direct is unavailable.

Supports Omarchy 4.0.0 and later with the Quattro shell.

The TV or phone has to be on the same Wi-Fi as this computer.

## Install

`omarchy plugin add` clones this repository and can enable the shell plugin. It does not install the streamer. Run `install.sh` after add, and again after an update if you want the desktop launcher and user service refreshed:

```bash
omarchy plugin add https://github.com/fpaulcris/omarchy-screenmirror.git --enable
bash ~/.config/omarchy/plugins/fpaulcris.screenmirror/install.sh
```

Enabling the plugin places the ScreenMirror button on the right side of the bar. Left click opens the panel. Right click starts or stops. Middle click refreshes.

## What you need

- `python3` (standard library only)
- `wf-recorder` (`omarchy pkg add wf-recorder` if it is missing)
- `qrencode` is optional. The window still shows the address without a QR code.
- `foot`, which the launcher and the panel's Open window button use

The stream listens on TCP 8080, 8000, and 8090, on every interface, for a private LAN. This plugin does not change your firewall. If the TV browser stays blank, allow those ports from your LAN (for example `192.168.0.0/16`, `10.0.0.0/8`, and `172.16.0.0/12`) and do not expose them to the internet.

An optional Hyprland rule keeps the status window floating:

```lua
o.window({ class = "screenmirror" }, { float = true, center = true, size = { 780, 720 } })
```

`install.sh` does not edit Hyprland, sudoers, or the firewall.

## Use

- App launcher: ScreenMirror
- Terminal: `screenmirror` (shows the address, press `q` to stop)
- Background: `screenmirror start` / `screenmirror stop`
- Address: `screenmirror url` or `screenmirror copy`
- Machine status: `screenmirror status --json`

On the TV, open the internet browser and go to the address on screen. The service is not started at login.

## Remove

```bash
bash ~/.config/omarchy/plugins/fpaulcris.screenmirror/install.sh --uninstall
omarchy plugin remove fpaulcris.screenmirror
```

`install.sh --uninstall` removes the command link, the user service, the launcher, and the icon files it wrote, and only when they still match what it installed. `omarchy plugin remove` removes the plugin checkout. Neither command changes the firewall or Hyprland.

## Layout

The shell plugin (bar button, panel, and status service) watches the `screenmirror` command. `systemd --user` runs `share/server.py`, so the picture keeps going if the shell restarts. The panel keeps these states separate: not installed, stopped, starting, live, and failed.

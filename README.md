# Screen Cast

Cast an Omarchy desktop to a TV or phone browser on the same Wi-Fi. The other device opens an HTTP address and shows a live picture of the screen.

The other device opens this address in a browser. The panel can also send the same picture to Chromecast, AirPlay, Miracast on this Wi-Fi, and a Fire TV player.

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

- Zig 0.17, used by `install.sh` to build the `screencast` binary
- `gpu-screen-recorder`, which captures the screen when it is installed. The stream still starts without it, using the built-in screen copy
- `pw-record` or `parecord`, which records the speakers into the cast. If neither is installed, the picture still plays and the cast is silent
- `avahi`, which the panel uses to list receivers on this Wi-Fi
- `qrencode` is optional. The window still shows the address without a QR code.
- `foot`, which the launcher uses for the status window

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
- `screencast receivers` lists devices. `screencast mirror <id>` starts sending the picture to that receiver and returns while it is still connecting. Another id can be started while the first is on; they share one picture. `screencast mirror status` lists each session. `screencast mirror stop <id>` returns that screen to what it was doing. `screencast mirror stop` stops every screen and leaves the browser stream running. `screencast stop` stops the stream and every screen.
- `screencast dial` lists receivers that speak DIAL. `screencast dial apps <id>` lists the apps on one of them. `screencast dial launch <id> <App> [payload]` starts an app and passes the extra text that app expects. `screencast dial stop <id> <App>` stops it. YouTube takes a video id (`v=...`). Netflix and the other catalog apps do not take a desktop address.
- Desktop and size: Follow Screen sends this laptop's screen. A numbered desktop stays on the laptop while you are looking at it, and moves to its own virtual screen when you switch away, so the picture keeps going. Sizes are 1280×720, 1920×1080, 2560×1440, and 3840×2160. 4K applies on the virtual screen. Windows on that desktop keep the same share of the screen when the size changes.
- The panel has two modes. Browser is this computer's address. Find Devices lists receivers on this Wi-Fi. A Chromecast, Nest Hub, Android TV that speaks Cast, AirPlay video receiver, or Miracast receiver on this Wi-Fi has a switch: on sends this desktop as H.264, with the sound that is playing through this computer's speakers. Several switches can be on at once. The computer keeps playing that sound too. The switch at the top of the panel stops the stream and every screen. A Fire TV switch sends this desktop to that TV's player. If the player refuses, the row says why. Android TV Remote is listed for keys after pairing. A Miracast TV that only uses Wi-Fi Direct stays off the list.
- Address: `screencast url`, `screencast copy`, or the QR code button
- Machine status: `screencast status --json`
- Frame rate and delay stays off until you turn it on. The panel switch, the corner of the browser picture, or `screencast preview on` shows frames per second and how many milliseconds of picture are still waiting. `screencast preview off` hides them again.

On the TV, open the internet browser and go to the address on screen. The page plays H.264 video and AAC sound. Samsung, LG, Sony Android, and Android TV browsers get that page. Press OK, or the Sound button, if the TV starts silent. Older Panasonic, Sharp, and HbbTV browsers get a JPEG picture and no sound. The service is not started at login.

## Remove

```bash
bash ~/.config/omarchy/plugins/fpaulcris.screenmirror/install.sh --uninstall
omarchy plugin remove fpaulcris.screenmirror
```

`install.sh --uninstall` removes the command link, the user service, the launcher, and the icon files it wrote, and only when they still match what it installed. `omarchy plugin remove` removes the plugin checkout. Neither command changes the firewall or Hyprland.

## Layout

The shell plugin (bar button, panel, and status service) calls the `screencast` command. `systemd --user` runs that same binary as `screencast serve`, so the picture keeps going if the shell restarts. The panel keeps these states separate: not installed, stopped, starting, live, and failed.

## Support

Questions and bugs go to the [GitHub issues](https://github.com/fpaulcris/omarchy-screencast/issues) for this repository. Report a suspected compromise through a GitHub private security advisory on that repository. The plugin runs unsandboxed in your session. A marketplace listing check is not a security audit.

# gp-tv

The software for the Raspberry Pi behind a TV. It puts a text dashboard for the day on the HDMI console, takes AirPlay video and audio, acts as a Bluetooth speaker, runs its own Wi-Fi network, and plays retro and native games with PlayStation pads. The repo is laid out the way the files sit on the Pi, with an installer that puts them there and an updater that keeps the Pi in step with `main`.

## What runs on the Pi

- **Dashboard.** `home/gabetv/gabetv` is a curses app on tty1, which logs in as `pi` by itself. The home screen shows today's calendar, tomorrow, the weather, a clock and where the daily routine is up to. Any button opens the menu: games, diagnostics, restart AirPlay, reboot.
- **GabeFi.** hostapd serves a 5 GHz network on wlan0, dnsmasq hands out 10.42.0.x addresses, and `gabepi-net` sets the address and NAT. The internet comes from a phone, over USB (eth1) or its hotspot on wlan1, which `gabepi-uplink-watch` keeps as a standby.
- **AirPlay.** uxplay mirrors a screen as "GabeTV" and shairport-sync plays audio as "GabeSound".
- **Bluetooth speaker.** `bt-agent` and `bt-speaker` let a phone pair without a PIN, and `bt-audio-link` routes it to the TV.
- **Games.** `gabetv-run` clears the stage for a game (stops AirPlay, pauses background services through `gabetv-gamemode`, gives the game realtime priority) and puts it all back after. `gabetv-emu` runs RetroArch through it. `ds3-pair` pairs a DualShock 3 when it is plugged in by USB, and `padhub` serves the pads over a WebSocket to a game running on another machine.

## Setting up a Pi

You need Raspberry Pi OS on Debian 13 with the user `pi`, and internet on the Pi. Run this once on the Pi:

```sh
sudo git clone https://github.com/Volcanex/gp-tv /opt/gp-tv && sudo /opt/gp-tv/install.sh
```

Or the same thing from another machine on GabeFi, where the Pi is 10.42.0.1:

```sh
ssh -t pi@10.42.0.1 'sudo git clone https://github.com/Volcanex/gp-tv /opt/gp-tv && sudo /opt/gp-tv/install.sh'
```

The first run writes the settings file, `/etc/gp-tv/tv.env`, from `tv.env.example`, and copies across anything the Pi already runs: the Wi-Fi name and password, the deny list, the hotspot it uses as an uplink, the calendar feed and the location. A Pi that works before the install works the same after it. On a new Pi, fill the file in and run the installer again:

```sh
sudo nano /etc/gp-tv/tv.env && sudo /opt/gp-tv/install.sh
```

`tv.env` is root only and never leaves the Pi. The installer also adds any packages that are missing, turns the old `g-system-update.timer` off, and adds a 720p video mode and the Wi-Fi country to the boot settings if they aren't there.

## How updates reach the Pi

`gp-tv-update.timer` runs every 5 minutes. It fetches `main`, moves `/opt/gp-tv` to it, and runs `install.sh` when the commit is one it hasn't installed. The installer writes only the files that changed and restarts only the services they belong to, so pushing to `main` is the whole deploy. If the dashboard changed and is on screen, it restarts too. The timer is paused while a game runs, so an update never lands in the middle of one, and an install that fails partway is tried again on the next run.

Don't edit files inside `/opt/gp-tv` on the Pi, because the next update overwrites them. Settings live in `/etc/gp-tv/tv.env` and the routine in `~/gabetv/routine.txt`, and updates leave both alone. `journalctl -u gp-tv-update` shows what each run did.

ROMs, media and game data are not in the repo. Neither is the PlayStation core, `pcsx_rearmed`, which Debian doesn't package, so it goes into `/usr/lib/aarch64-linux-gnu/libretro` by hand.

## Licence

Copyright (C) 2026 Gabriel Penman. Licensed under the [GNU Affero General Public License v3.0 only](LICENSE). You can read it, run it, change it and share it for any purpose. If you share a changed copy, or run one as a network service, you must offer its source under the same licence.

Required Notice: Copyright Gabriel Penman (https://gabrielpenman.com)

#!/bin/bash
# GabePi uplink watchdog.
#
# wlan1 (the usb dongle) is the STANDBY uplink to the iphone hotspot, saved in
# NetworkManager as gabepi-uplink by install.sh from UPLINK_SSID / UPLINK_PSK in
# /etc/gp-tv/tv.env. With UPLINK_SSID empty there is no standby, only NAT upkeep. eth1
# (iphone over usb) is preferred at metric 100; wlan1 sits at metric 600.
#
# THE TENSION THIS SOLVES:
#   Scanning wlan1 sweeps every channel including ch36 where GabeFi lives,
#   from an antenna inches away. That desenses the AP and stutters airplay.
#   So we must NOT scan often while a working uplink already exists.
#   But when the uplink is GONE, we need to reconnect fast.
#
# Earlier version got this wrong: it slept 300s after each check, so a tether
# unplugged just after a check waited the full 5 minutes. Measured 315s on
# 2026-09-22. Now the POLL is always quick and only the SCAN is backed off.
#
#   no default route at all  -> urgent, try every poll (15s)
#   route exists, not wlan1  -> standby, try at most every 300s
#   wlan1 already up         -> nothing to do, just keep NAT fresh
POLL=15
BACKOFF=300
last_try=0

while true; do
  now=$(date +%s)
  routes=$(/usr/sbin/ip route show default 2>/dev/null)

  if echo "$routes" | grep -q wlan1; then
    :                                    # standby is up, nothing to do
  else
    if [ -z "$routes" ]; then
      due=0                              # no internet at all: act now
    else
      due=$(( now - last_try < BACKOFF ))
    fi
    # Read each time, so an edited tv.env applies without a restart.
    [ "$due" -eq 0 ] && UPLINK_SSID=$(. /etc/gp-tv/tv.env 2>/dev/null; echo "${UPLINK_SSID:-}")
    if [ "$due" -eq 0 ] && [ -n "$UPLINK_SSID" ]; then
      last_try=$now
      /usr/sbin/rfkill unblock wifi 2>/dev/null
      /usr/sbin/ip link set wlan1 up 2>/dev/null
      /usr/bin/nmcli device set wlan1 managed yes 2>/dev/null
      if /usr/bin/nmcli -g SSID device wifi list ifname wlan1 2>/dev/null | grep -qiF -- "$UPLINK_SSID"; then
        /usr/bin/nmcli connection up gabepi-uplink >/dev/null 2>&1
      else
        /usr/bin/nmcli device wifi rescan ifname wlan1 >/dev/null 2>&1
      fi
    fi
  fi

  /usr/local/sbin/gabepi-nat.sh >/dev/null 2>&1
  sleep $POLL
done

#!/bin/bash
# NAT for the GabeFi AP (10.42.0.0/24).
# Masquerades out whatever interface currently holds the default route, so a new
# uplink (iPhone USB tethering, a different dongle, ethernet) works without edits.
# This is the bug that bit twice: rules hardcoded to one interface silently stop
# covering traffic the moment the uplink changes, and clients get "connected, no internet".
UPLINKS=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | sort -u)
UPLINKS="$UPLINKS wlan1 eth0"
for up in $(echo "$UPLINKS" | tr ' ' '\n' | sort -u); do
  [ -z "$up" ] && continue
  [ "$up" = "wlan0" ] && continue   # never NAT out of the AP itself
  iptables -t nat -C POSTROUTING -s 10.42.0.0/24 -o "$up" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s 10.42.0.0/24 -o "$up" -j MASQUERADE
  iptables -C FORWARD -i "$up" -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -i "$up" -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
  iptables -C FORWARD -i wlan0 -o "$up" -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -i wlan0 -o "$up" -j ACCEPT
done
exit 0

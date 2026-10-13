#!/bin/bash
# Link any connected Bluetooth A2DP source to the speaker output.
# PipeWire does not do this automatically for a phone streaming to a Pi.
export XDG_RUNTIME_DIR=/run/user/$(id -u)
while true; do
  SINK_FL=$(pw-link -i 2>/dev/null | grep -m1 "alsa_output.*playback_FL")
  SINK_FR=$(pw-link -i 2>/dev/null | grep -m1 "alsa_output.*playback_FR")
  if [ -n "$SINK_FL" ]; then
    for s in $(pw-link -o 2>/dev/null | grep "bluez_input.*output_FL"); do
      pw-link "$s" "$SINK_FL" 2>/dev/null
    done
    for s in $(pw-link -o 2>/dev/null | grep "bluez_input.*output_FR"); do
      pw-link "$s" "$SINK_FR" 2>/dev/null
    done
  fi
  sleep 3
done

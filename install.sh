#!/bin/bash
# gp-tv installer: lays this repo onto the Pi. Safe to run any number of times.
#
#   sudo /opt/gp-tv/install.sh
#
# Only files whose content changed are written, and only the services those
# files belong to are restarted, so a run with nothing new touches nothing.
# gp-tv-update runs it after every pull.
#
# The repo mirrors the Pi:
#   etc/   -> /etc            a .in file is a template filled from tv.env
#   bin/   -> /usr/local/bin
#   sbin/  -> /usr/local/sbin
#   home/  -> /home/pi        owned by pi
set -euo pipefail
# Run over ssh, a hostapd restart can drop the session: finish regardless.
trap '' HUP

REPO=$(cd "$(dirname "$0")" && pwd)
TV_USER=pi
TV_HOME=/home/$TV_USER
ENV_FILE=/etc/gp-tv/tv.env
STAMP=/var/lib/gp-tv/installed

PACKAGES=(
  git iptables iw rfkill network-manager hostapd dnsmasq
  bluez bluez-tools shairport-sync avahi-daemon uxplay
  gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-libav
  pipewire pipewire-pulse wireplumber python3 python3-websockets
  usbmuxd console-setup kbd
  retroarch libretro-nestopia libretro-snes9x libretro-genesisplusgx
  libretro-gambatte libretro-mgba libretro-beetle-vb libretro-beetle-wswan
  chocolate-doom doom-wad-shareware freedoom opentyrian supertux cdogs-sdl
)
SYSTEM_UNITS=(gabepi-net.service gabepi-uplink-watch.service hostapd.service
  dnsmasq.service shairport-sync.service bt-agent.service bt-speaker.service
  gp-tv-update.timer)
USER_UNITS=(bt-audio-link.service padhub.service uxplay.service)

[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }
id "$TV_USER" >/dev/null 2>&1 || { echo "there is no user $TV_USER on this box" >&2; exit 1; }

warn() { echo "warning: $*" >&2; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

CHANGED=()
# put SRC DST MODE [OWNER]: write DST only when its content differs.
put() {
  local src=$1 dst=$2 mode=$3 owner=${4:-root}
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then return 0; fi
  install -m "$mode" -o "$owner" -g "$owner" "$src" "$dst"
  CHANGED+=("$dst")
  echo "  updated $dst"
}
# changed PREFIX...: did this run write anything under one of these paths?
changed() {
  local c p
  for c in "${CHANGED[@]}"; do
    for p in "$@"; do [[ $c == "$p"* ]] && return 0; done
  done
  return 1
}
RESTART=()
queue() {
  local u
  for u in "$@"; do [[ " ${RESTART[*]} " == *" $u "* ]] || RESTART+=("$u"); done
}

# ---- packages: only the missing ones, so a routine update never runs apt ----
missing=()
for p in "${PACKAGES[@]}"; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "ok installed" || missing+=("$p")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "installing ${missing[*]}"
  { apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing[@]}"; } \
    || warn "apt did not finish, carrying on with what is installed"
fi

# ---- settings ----
install -d -m 755 /etc/gp-tv /var/lib/gp-tv
if [ ! -f "$ENV_FILE" ]; then
  # First install: start from the example and keep whatever this Pi already
  # runs, so moving a working box onto gp-tv changes nothing it does.
  echo "writing $ENV_FILE"
  python3 - "$REPO/tv.env.example" "$ENV_FILE" "$TV_HOME/gabetv/gabetv" <<'PY'
import os, re, shlex, subprocess, sys
example, out, old_gabetv = sys.argv[1:]

def read(path):
    try:
        return open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return ""

found = {}
conf = read("/etc/hostapd/hostapd.conf")
for key, name in (("ssid", "GABEFI_SSID"), ("wpa_passphrase", "GABEFI_PSK"),
                  ("country_code", "WIFI_COUNTRY")):
    m = re.search(r"^%s=(.+)$" % key, conf, re.M)
    if m and "${" not in m.group(1):
        found[name] = m.group(1).strip()
macs = re.findall(r"^\s*((?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2})\s*$",
                  read("/etc/hostapd/gabefi-deny.txt"), re.M)
if macs:
    found["GABEFI_DENY_MACS"] = " ".join(macs)
try:
    ssid = subprocess.run(["nmcli", "-g", "802-11-wireless.ssid", "connection", "show",
                           "gabepi-uplink"], capture_output=True, text=True, timeout=10).stdout.strip()
    if ssid:
        found["UPLINK_SSID"] = ssid
except Exception:
    pass
# The dashboard before gp-tv had its feed and location written into the script.
old = read(old_gabetv)
m = re.search(r'^CAL_URL = "([^"?%]+)', old, re.M)
if m:
    found["GABETV_CAL_URL"] = m.group(1)
m = re.search(r"latitude=([-\d.]+)&longitude=([-\d.]+)", old)
if m:
    found["GABETV_LAT"], found["GABETV_LON"] = m.groups()

lines = []
for line in read(example).splitlines():
    key = line.split("=", 1)[0]
    if not line.startswith("#") and key in found:
        line = "%s=%s" % (key, shlex.quote(found[key]))
    lines.append(line)
fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as f:
    f.write("\n".join(lines) + "\n")
print("  kept from this Pi: " + (", ".join(sorted(found)) or "nothing"))
PY
fi
chown root:root "$ENV_FILE"
chmod 600 "$ENV_FILE"
set -a
GABEFI_SSID=GabeFi GABEFI_PSK= WIFI_COUNTRY=GB GABEFI_DENY_MACS= UPLINK_SSID= UPLINK_PSK=
GABETV_CAL_URL= GABETV_LAT= GABETV_LON= GABETV_TZ=Europe/London
. "$ENV_FILE"
set +a

# ---- /etc ----
while IFS= read -r -d '' f; do
  rel=${f#"$REPO"/}
  dst=/${rel%.in}
  src=$f
  mode=644
  case $dst in
    /etc/hostapd/hostapd.conf)
      if [ ${#GABEFI_PSK} -lt 8 ] || [ ${#GABEFI_PSK} -gt 63 ]; then
        warn "GABEFI_PSK in $ENV_FILE is not 8 to 63 characters, so $dst is left alone"
        continue
      fi
      mode=600 ;;
    /etc/sudoers.d/*)
      mode=440
      visudo -cqf "$src" || { warn "$rel fails visudo, skipped"; continue; } ;;
  esac
  if [[ $f == *.in ]]; then
    python3 -c 'import os, string, sys
sys.stdout.write(string.Template(open(sys.argv[1]).read()).substitute(os.environ))' "$f" > "$TMP/rendered"
    src=$TMP/rendered
  fi
  install -d -m 755 "$(dirname "$dst")"
  put "$src" "$dst" "$mode"
done < <(find "$REPO/etc" -type f -print0 | sort -z)

# Rewritten only when the addresses change, since a new deny list means
# restarting hostapd, which drops everyone on GabeFi for a moment.
deny_now=$(grep -v '^#' /etc/hostapd/gabefi-deny.txt 2>/dev/null | grep . || true)
deny_want=$(for m in $GABEFI_DENY_MACS; do echo "$m"; done)
if [ "$deny_now" != "$deny_want" ] || [ ! -f /etc/hostapd/gabefi-deny.txt ]; then
  {
    cat <<'TXT'
# Devices GabeFi refuses. Written by gp-tv install.sh from GABEFI_DENY_MACS in
# /etc/gp-tv/tv.env: edit it there, not here.
#
# The phone that is the Pi's uplink (USB tether on eth1, hotspot on wlan1)
# belongs here. If it also joins GabeFi it routes through itself: iOS finds no
# internet, leaves after about 9s and retries a minute later. That once made 237
# associate and deauth cycles in an afternoon, and read as "the wifi keeps
# dropping". Give the Pi a real uplink and the list can go.
#
# It is the phone's private Wi-Fi address for GabeFi, which changes if Private
# Wi-Fi Address is toggled for GabeFi on the phone.
TXT
    [ -n "$deny_want" ] && echo "$deny_want"
  } > "$TMP/deny"
  put "$TMP/deny" /etc/hostapd/gabefi-deny.txt 644
fi

# The dashboard's settings, readable by pi. tv.env itself stays root only.
for k in GABETV_CAL_URL GABETV_LAT GABETV_LON GABETV_TZ; do
  printf '%s=%q\n' "$k" "${!k}"
done > "$TMP/gabetv.env"
put "$TMP/gabetv.env" /etc/gp-tv/gabetv.env 644

# ---- programs ----
for f in "$REPO"/bin/*; do put "$f" "/usr/local/bin/${f##*/}" 755; done
for f in "$REPO"/sbin/*; do put "$f" "/usr/local/sbin/${f##*/}" 755; done

# ---- pi's home ----
while IFS= read -r -d '' f; do
  dst=$TV_HOME/${f#"$REPO"/home/}
  if [ -x "$f" ]; then mode=755; else mode=644; fi
  runuser -u "$TV_USER" -- mkdir -p "$(dirname "$dst")"
  put "$f" "$dst" "$mode" "$TV_USER"
done < <(find "$REPO/home" -type f ! -name '*.pyc' -print0 | sort -z)
# routine.txt is personal, so it is seeded once and then belongs to the Pi.
if [ ! -f "$TV_HOME/gabetv/routine.txt" ]; then
  install -m 644 -o "$TV_USER" -g "$TV_USER" "$TV_HOME/gabetv/routine.example.txt" "$TV_HOME/gabetv/routine.txt"
fi

for g in video render audio input bluetooth; do
  if getent group "$g" >/dev/null && ! id -nG "$TV_USER" | grep -qw "$g"; then
    usermod -aG "$g" "$TV_USER"
  fi
done
loginctl enable-linger "$TV_USER"

# ---- the standby uplink, kept in NetworkManager rather than in a script ----
uplink() {
  [ -n "$UPLINK_SSID" ] && [ -n "$UPLINK_PSK" ] || return 0
  if nmcli connection show gabepi-uplink >/dev/null 2>&1; then
    [ "$(nmcli -g 802-11-wireless.ssid connection show gabepi-uplink)" = "$UPLINK_SSID" ] \
      && [ "$(nmcli -s -g 802-11-wireless-security.psk connection show gabepi-uplink)" = "$UPLINK_PSK" ] \
      && return 0
    nmcli connection modify gabepi-uplink 802-11-wireless.ssid "$UPLINK_SSID" \
      wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$UPLINK_PSK" || return 1
    echo "  updated NetworkManager connection gabepi-uplink"
  else
    nmcli connection add type wifi ifname wlan1 con-name gabepi-uplink ssid "$UPLINK_SSID" \
      wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$UPLINK_PSK" \
      connection.autoconnect yes connection.autoconnect-retries 0 >/dev/null || return 1
    echo "  added NetworkManager connection gabepi-uplink"
  fi
}
uplink || warn "could not set up the gabepi-uplink connection"

# ---- boot settings: only ever added, never removed ----
REBOOT=0
CMDLINE=/boot/firmware/cmdline.txt
if [ -f "$CMDLINE" ]; then
  line=$(head -n1 "$CMDLINE")
  new=$line
  # A fixed 720p mode for the console font and uxplay, and the wifi country.
  for want in "video=HDMI-A-1:1280x720@60D" "cfg80211.ieee80211_regdom=$WIFI_COUNTRY"; do
    key=${want%%=*}=
    [[ $want == video=* ]] && key=video=HDMI-A-1:
    case " $new " in *" $want "*) continue ;; esac
    kept=()
    for t in $new; do [[ $t == "$key"* ]] || kept+=("$t"); done
    new="${kept[*]} $want"
  done
  if [ "$new" != "$line" ]; then
    printf '%s\n' "$new" > "$CMDLINE"
    echo "  updated $CMDLINE"
    REBOOT=1
  fi
fi
CONFIG=/boot/firmware/config.txt
if [ -f "$CONFIG" ]; then
  add=()
  for want in disable_overscan=1 dtparam=act_led_trigger=none dtparam=act_led_activelow=off \
              dtparam=pwr_led_trigger=none; do
    grep -qxF "$want" "$CONFIG" || add+=("$want")
  done
  if [ ${#add[@]} -gt 0 ]; then
    { printf '\n[all]\n# gp-tv: no overscan, LEDs off\n'; printf '%s\n' "${add[@]}"; } >> "$CONFIG"
    echo "  updated $CONFIG"
    REBOOT=1
  fi
fi

# ---- system services ----
systemctl daemon-reload
systemctl unmask -q hostapd.service 2>/dev/null || true
if systemctl is-enabled -q g-system-update.timer 2>/dev/null; then
  systemctl disable -q --now g-system-update.timer \
    && echo "  retired g-system-update.timer, gp-tv-update.timer replaces it"
fi
systemctl enable -q "${SYSTEM_UNITS[@]}" || warn "not every system unit could be enabled"

if changed /etc/sysctl.d/; then sysctl -q --system || warn "sysctl did not reload"; fi
if changed /etc/udev/; then udevadm control --reload || warn "udev did not reload"; fi
if changed /etc/NetworkManager/; then systemctl reload NetworkManager || warn "NetworkManager did not reload"; fi
if changed /etc/systemd/journald.conf.d/; then queue systemd-journald.service; fi
if changed /usr/local/sbin/gabepi-nat.sh; then queue gabepi-net.service; fi
if changed /etc/bluetooth/; then queue bluetooth.service; fi
if changed /etc/hostapd/ /etc/default/hostapd; then queue hostapd.service; fi
if changed /etc/dnsmasq.d/; then queue dnsmasq.service; fi
if changed /etc/shairport-sync.conf; then queue shairport-sync.service; fi
if changed /usr/local/sbin/gabepi-uplink-watch.sh; then queue gabepi-uplink-watch.service; fi
# A changed unit file or drop-in restarts its unit. Not tty1, handled below,
# and not the updater service, which may be the thing running this script.
for c in "${CHANGED[@]}"; do
  [[ $c == /etc/systemd/system/* ]] || continue
  u=${c#/etc/systemd/system/}
  u=${u%%/*}
  u=${u%.d}
  case $u in getty@tty1.service|gp-tv-update.service) continue ;; esac
  queue "$u"
done
for u in "${RESTART[@]}"; do
  echo "  restarting $u"
  systemctl restart "$u" || warn "$u did not restart"
done
for u in "${SYSTEM_UNITS[@]}"; do
  systemctl is-active -q "$u" || systemctl start "$u" || warn "$u did not start"
done

# ---- pi's user services ----
usys() { runuser -u "$TV_USER" -- env XDG_RUNTIME_DIR="/run/user/$(id -u "$TV_USER")" systemctl --user "$@"; }
usys daemon-reload || warn "pi's user manager is not answering"
usys enable -q "${USER_UNITS[@]}" || warn "could not enable pi's user services"
U=$TV_HOME/.config/systemd/user
for u in "${USER_UNITS[@]}"; do
  case $u in
    bt-audio-link.service) files=("$U/$u" "$TV_HOME/bt-audio-link.sh") ;;
    padhub.service) files=("$U/$u" "$TV_HOME/padhub/") ;;
    *) files=("$U/$u") ;;
  esac
  if changed "${files[@]}"; then
    echo "  restarting $u for pi"
    usys restart "$u" || warn "$u did not restart"
  elif ! usys is-active -q "$u"; then
    usys start "$u" || warn "$u did not start"
  fi
done

# ---- the dashboard on tty1 ----
if changed "$TV_HOME/gabetv/gabetv" "$TV_HOME/.bash_profile" /etc/gp-tv/gabetv.env \
           /etc/systemd/system/getty@tty1.service.d/; then
  if pgrep -t tty1 -f gabetv/gabetv >/dev/null; then
    echo "  restarting the dashboard on tty1"
    systemctl restart getty@tty1.service || warn "tty1 did not restart"
  else
    echo "  the dashboard is not on screen, it picks up the change when it next starts"
  fi
fi

git -C "$REPO" rev-parse HEAD > "$STAMP" 2>/dev/null || true
if [ "$REBOOT" = 1 ]; then echo "boot settings changed, reboot to apply them"; fi
echo "gp-tv installed ($(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo "not a checkout"))"

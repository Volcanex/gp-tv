# GabeTV text dashboard on the HDMI console (tty1 autologs in as pi).
# Escape hatches: press q in the menu to drop to this shell, or
# "touch ~/.no-menu" to stop it launching at all.
# Note this does NOT exec, so quitting the menu leaves you at a prompt.
# gabetv.env holds the calendar feed and weather location, written by install.sh.
# The bigger Terminus font is for reading the dashboard across the room.
if [ "$(tty)" = "/dev/tty1" ] && [ ! -f "$HOME/.no-menu" ]; then
  setfont Uni2-TerminusBold20x10 2>/dev/null
  [ -r /etc/gp-tv/gabetv.env ] && { set -a; . /etc/gp-tv/gabetv.env; set +a; }
  "$HOME/gabetv/gabetv"
fi

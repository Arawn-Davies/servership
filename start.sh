#!/bin/bash
# KVM engine: ONE headless X display per BMC so each console is fully isolated
# (no shared desktop, no switching within noVNC):
#   :1 / Xvnc 5901  -> iLO2   (Firefox 52 + NPAPI)
#   :2 / Xvnc 5902  -> iDRAC6 (firefox-esr + javaws vKVM)
# Each display gets a kiosk WM (matchbox) so the browser/console fills the
# screen: no desktop, no titlebars, no terminal. Consoles are launched by
# clicking a card in the web app, never from a shell. Nothing is published to
# the host: Xvnc:5901/5902 and the launcher:9000 are reached over the compose
# network only.
set -e

rm -f /tmp/.X1-lock /tmp/.X2-lock /tmp/.X11-unix/X1 /tmp/.X11-unix/X2 2>/dev/null || true

Xvnc :1 -geometry 1280x1024 -depth 24 -SecurityTypes None -AlwaysShared &
Xvnc :2 -geometry 1280x1024 -depth 24 -SecurityTypes None -AlwaysShared &
sleep 2

DISPLAY=:1 matchbox-window-manager -use_titlebar no &
DISPLAY=:2 matchbox-window-manager -use_titlebar no &

# launch listener (foreground -> keeps the container alive)
exec python /usr/local/bin/launchd.py

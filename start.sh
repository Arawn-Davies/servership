#!/bin/bash
# Bring up a headless X desktop and expose it over the browser via noVNC.
set -e

export DISPLAY=:1
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true

# VNC server (no password — it's on your LAN behind noVNC; add -SecurityTypes
# VncAuth + a passwd file if you want a prompt).
Xvnc :1 -geometry 1280x1024 -depth 24 -SecurityTypes None -AlwaysShared &
sleep 2

fluxbox &
# A terminal so you can type `ilo2 <ip>` / `idrac6 <ip>` straight away.
xterm -geometry 100x30+20+20 -title "BMC console — run: ilo2 <ip>  |  idrac6 <ip>" &

# Serve the desktop at http://<host>:8080/vnc.html (modern noVNC in /opt/novnc)
websockify --web=/opt/novnc 8080 localhost:5901

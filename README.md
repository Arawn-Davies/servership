# bmc-console — legacy iLO2 / iDRAC6 KVM appliance

A throwaway Docker container that runs the **old Java remote-console applets**
for **HP iLO2** (DL320 G6 / SQUIDBLADE) and **Dell iDRAC6** (R510 / SQUIDBOAT),
which modern Windows 11 + browsers can no longer launch. You view its desktop
from any modern browser over **noVNC**; the container does the dead-crypto
(SSLv3/TLS1.0, RC4/3DES, expired self-signed cert) handshake on the isolated
side.

```
Win11 browser ──HTTPS/noVNC──> [container: OpenJDK8 + IcedTea-Web + loosened crypto] ──legacy TLS──> iLO2 / iDRAC6
```

## Why not just fix Windows 11?
You can't. The iLO2 **ActiveX** console is IE-only and dead; modern Java refuses
the applets; modern TLS refuses the ciphers. The fix is to *contain* the legacy
stack, not install it on your daily machine. The **Java** consoles do everything
the ActiveX one did — full KVM + virtual media (mount ISOs).

## Run it
On the Win11 box (Docker Desktop/WSL2) **or** any Proxmox LXC with Docker:

```bash
docker compose up -d --build
```

Then open **http://localhost:8080/vnc.html** and hit Connect. You get a small
Linux desktop with a terminal.

## Use it
In the container's terminal:

```bash
ilo2 10.0.0.20              # opens iLO2 web UI -> log in -> Remote Console (Java)
idrac6 10.0.0.80 root calvin   # authenticates and launches the vKVM applet directly
```

- **iLO2:** Firefox opens the iLO web UI (TLS already loosened). Log in →
  *Remote Console* → *Java Integrated Remote Console*. The `.jnlp` hands off to
  `javaws` automatically.
- **iDRAC6:** the script logs in over legacy TLS, pulls the `viewer.jnlp`, and
  fires `javaws`. If auto-login fails (firmware quirks vary), it falls back to
  opening the web UI so you can launch *Console* manually.

## If a console won't launch (expected fiddling)
These BMCs are cranky; tune inside the running container (`docker exec -it
bmc-console bash`):

- **Applet blocked as untrusted:** add the BMC to the exception site list —
  `itweb-settings` → *Security* → add `https://<bmc-ip>`.
- **TLS handshake still fails:** the `--ciphers DEFAULT@SECLEVEL=0` in `idrac6`
  is the lever; OpenJDK8 in bullseye may have dropped the very oldest ciphers.
  If so, swap the base image for an older JRE build (adoptopenjdk 8u fairly
  early, or Oracle JRE 7) — that's the one knob that occasionally forces a
  rebuild.
- **Virtual media / mouse sync** options live in the applet's own menus once
  it's up.

## Notes
- No VNC password (LAN + noVNC). Add `-SecurityTypes VncAuth` + a passwd file in
  `start.sh` if you want a prompt.
- The Dell default creds are `root` / `calvin`; HP iLO2 default is on the pull-tab.
- This is deliberately disposable — rebuild anytime, keep nothing in it.

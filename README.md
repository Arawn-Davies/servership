# bmc-console — legacy iLO2 / iDRAC6 KVM appliance

A throwaway Docker container that runs the **old Java remote-console applets**
for **HP iLO2** and **Dell iDRAC6**, which modern Windows 11 + browsers can no
longer launch. You view its desktop from any modern browser over **noVNC**; the
container does the dead-crypto (SSLv3/TLS1.0, RC4/3DES, expired self-signed
cert) handshake and runs the ancient Java on the isolated side.

```
Win11 browser ──HTTPS/noVNC──> [container: OpenJDK8 + IcedTea-Web + FF52 + loosened crypto] ──legacy TLS──> iLO2 / iDRAC6
```

Confirmed working against HP DL320 G6 (iLO2) and Dell PowerEdge R510 (iDRAC6),
full graphical KVM + virtual media, from Windows 11 Firefox.

## Why not just fix Windows 11?
You can't. The iLO2 **ActiveX** console is IE-only and dead; modern Java refuses
the applets; modern browsers dropped the NPAPI plugin the iLO2 applet needs; and
modern TLS refuses the ciphers. The fix is to *contain* the legacy stack, not
install it on your daily machine. The **Java** consoles do everything the
ActiveX one did — full KVM + virtual media (mount ISOs).

## Build prerequisite — fetch Firefox 52 ESR
iLO2's console is an in-browser NPAPI `<applet>`, so it needs **Firefox 52.9
ESR** (the last NPAPI release). It's ~56 MB and gitignored, and stretch's old
wget can't fetch Mozilla's modern TLS — so grab it host-side first:

```bash
curl -Lo firefox-52.9.0esr.tar.bz2 \
  https://archive.mozilla.org/pub/firefox/releases/52.9.0esr/linux-x86_64/en-US/firefox-52.9.0esr.tar.bz2
```

(Everything else — OpenJDK 8, IcedTea-Web, the NPAPI plugin grafted from
Debian jessie, noVNC — is fetched during `docker build`.)

## Run it
On the Win11 box (Docker Desktop/WSL2) **or** any Proxmox LXC with Docker:

```bash
docker compose up -d --build
```

Then open **http://localhost:8080/vnc.html** and hit Connect. You get a small
Linux desktop with a terminal.

## Use it
In the container's terminal (right-click desktop → the xterm is already open):

```bash
idrac6 <idrac-ip> root calvin   # Dell: auto-login + launch the vKVM applet
ilo2   <ilo-ip>                 # HP: opens the iLO2 web UI in Firefox 52 (NPAPI)
```

- **iDRAC6** — the script authenticates over legacy TLS and hands the vKVM
  `.jnlp` to `javaws`. Or just use the web UI's *Console/Media → Launch Virtual
  Console* (Plug-in Type must be **Java**, not ActiveX).
- **iLO2** — Firefox 52 (with the NPAPI Java plugin) opens the iLO web UI. Log
  in → **Remote Console** tab → the applet loads inline. First load may show a
  Java security prompt — allow it.

## Virtual media (mount ISOs)
Drop `.iso` files into `./isos` (or point the volume in `docker-compose.yml` at
any host folder, e.g. `/mnt/c/Users/you/Downloads` on WSL2). They appear inside
the console's **Virtual Media / Image File** picker at `/isos`.

## How it works / notable gotchas
The fiddly bits, in case a rebuild ever misbehaves:

- Base is **debian:stretch** (via `archive.debian.org`) — the last Debian with
  openjdk-8 + icedtea-netx + firefox-esr. Needs `bzip2` apt-installed or the
  FF52 `tar xjf` fails.
- **noVNC pinned to 1.1.0** — newest version that still sends the `binary` WS
  sub-protocol the distro's websockify 0.8 demands (1.4 drops it → HTTP 400).
- **NPAPI plugin** (for iLO2) is grafted from jessie's icedtea-web **1.5.3** —
  the native `IcedTeaPlugin.so` **and both** `plugin.jar` + `netx.jar`. All
  three must be the same version or the applet throws `NoSuchMethodError` on
  `NetxPanel.<init>`. That `.so` hardcodes a java-7 path, so a symlink points
  `/usr/lib/jvm/java-7-openjdk-amd64` at java-8's JRE.
- `java.security` has its `*.disabledAlgorithms` lists blanked to re-enable the
  dead crypto the BMCs speak.

## Notes
- No VNC password (LAN + noVNC). Add `-SecurityTypes VncAuth` + a passwd file in
  `start.sh` if you want a prompt.
- Dell default creds are `root` / `calvin`; HP iLO2 default is on the pull-tab.
- Deliberately disposable — rebuild anytime, keep nothing in it.

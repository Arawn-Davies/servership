# ⚓ Servership

> **All hands on your server fleet.**
> One bridge for legacy lights-out management: **iLO2**, **iDRAC6**, a unified **IPMI dashboard**, and full **KVM consoles**, from any modern browser.

Servership is a self-hosted control panel for out-of-band management of older
servers whose native tooling (ActiveX consoles, NPAPI Java applets, dead TLS
ciphers) modern browsers and operating systems can no longer run. It quarantines
all of that legacy in a container and gives you one clean, modern web UI.

Confirmed against **HP ProLiant DL320 G6** (iLO2) and **Dell PowerEdge R510** (iDRAC6).

---

## What you get

- **IPMI dashboard** across every BMC, vendor-agnostic (one protocol, HP + Dell
  identical): live power state, draw in watts, temperatures, fan RPM, voltages,
  and recent system-event-log entries.
- **One-click power control**: on / off / cycle / reset / soft-shutdown, plus
  chassis identify LED and clear-SEL.
- **Graphical KVM consoles** for iLO2 and iDRAC6, each **isolated on its own
  page**, embedded inline via noVNC. No ancient browser or Java on your machine.
- **Virtual media**: mount ISOs into the console from a host folder.

## Architecture

```
                         Servership
  ┌──────────────────────────────────────────────────────────────┐
  browser ──http:8088──▶  web  (Sinatra + Tailwind)
                          │  · IPMI dashboard + power   (ipmitool)
                          │  · serves noVNC 1.4
                          │  · proxies the VNC WebSocket
                          │
                          ├─ws /websockify/ilo──▶ engine :5901 ─┐
                          └─ws /websockify/idrac─▶ engine :5902 ─┤
                                                                  │
        IPMI 2.0 (lanplus) ───────────────────────────────┐      │
                                                           ▼      ▼
                                                    iLO2 / iDRAC6 BMCs
  └──────────────────────────────────────────────────────────────┘
```

Two containers, one compose project:

- **`web`** (`ruby:3-slim`): the whole UI and the only thing you open in a
  browser. Sinatra + Tailwind, `ipmitool` for the dashboard and power actions,
  serves modern **noVNC 1.4**, and proxies the VNC WebSocket in-process
  (faye-websocket) so there is a single origin and a single port.
- **`engine`/`console`** (`debian:stretch`): the legacy KVM engine. **One Xvnc
  display per BMC** (`:1`/5901 for iLO2, `:2`/5902 for iDRAC6) so the consoles
  are fully isolated, each under a kiosk window manager so the console fills the
  screen (no desktop, no titlebars, no terminal). Runs **Firefox 52 + IcedTea
  NPAPI** for iLO2's in-browser applet and **firefox-esr + javaws** for iDRAC6's
  vKVM. Nothing is published to the host; it is reached only by `web` over the
  compose network.

## Why it exists (and why it is hard)

Modern machines simply cannot drive these BMCs anymore:

- iLO2's **ActiveX** console is Internet-Explorer-only and dead.
- The **Java applets** need the **NPAPI** browser plugin, which every current
  browser removed.
- The BMCs speak **SSLv3 / TLS 1.0 with RC4 / 3DES**, which modern TLS refuses.
- Their **self-signed certs** are long expired.

Servership contains all of that in the engine container so your daily driver
stays clean and modern.

## Quickstart

1. **Fetch Firefox 52 ESR** (host-side; it is gitignored, ~56 MB, and stretch's
   old wget cannot negotiate Mozilla's modern TLS):

   ```bash
   curl -Lo firefox-52.9.0esr.tar.bz2 \
     https://archive.mozilla.org/pub/firefox/releases/52.9.0esr/linux-x86_64/en-US/firefox-52.9.0esr.tar.bz2
   ```

2. **Configure credentials** (never committed):

   ```bash
   cp .env.example .env
   # edit .env with your BMC IPs + creds
   ```

3. **Build and run:**

   ```bash
   docker compose up -d --build
   ```

4. **Open** http://localhost:8088

Everything else (OpenJDK 8, IcedTea-Web, the NPAPI plugin grafted from Debian
jessie, noVNC, ipmitool) is fetched during the build.

## Usage

- **Dashboard** (`/dashboard`): live readings and power controls for every node,
  auto-refreshing. Destructive actions ask for confirmation.
- **Consoles** (`/console/ilo`, `/console/idrac`): click a card and the console
  launches automatically and paints inline, fullscreen. Each BMC is isolated on
  its own page. For iLO2: log in, open **Remote Console**. For iDRAC6: log in,
  **Console/Media -> Launch Virtual Console** (plug-in type Java).
- **Virtual media**: drop `.iso` files into `./isos` (or repoint the volume in
  `docker-compose.yml`, e.g. `/mnt/c/Users/you/Downloads` on WSL2). They appear
  in the console's **Virtual Media / Image File** picker at `/isos`.

## Configuration (`.env`)

| Variable | Meaning |
|---|---|
| `ILO_IP` / `ILO_USER` / `ILO_PASS` | iLO2 management address and login |
| `IDRAC_IP` / `IDRAC_USER` / `IDRAC_PASS` | iDRAC6 management address and login |

Values are read literally (no quotes). BMC credentials live only server-side and
never reach the browser.

## Tests

```bash
docker exec servership-web bundle exec rspec   # or bmc-web, per container_name
```

RSpec + Rack::Test cover routing, the power-action allow-list, the launch
trigger, and noVNC embedding, with IPMI stubbed so tests never touch a real BMC.

## How it works (the legacy gauntlet)

The fiddly bits, documented so a rebuild never becomes archaeology:

- **Engine base is `debian:stretch`** (via `archive.debian.org`): the last Debian
  carrying `openjdk-8` + `icedtea-netx` + `firefox-esr` together. Needs `bzip2`
  apt-installed or the FF52 `tar xjf` fails.
- **iLO2 NPAPI plugin** is grafted from jessie's icedtea-web **1.5.3**: the native
  `IcedTeaPlugin.so` **and both** `plugin.jar` + `netx.jar`. All three must be the
  same version or the applet throws `NoSuchMethodError` on `NetxPanel.<init>`.
  The `.so` hardcodes a java-7 path, so a symlink points
  `/usr/lib/jvm/java-7-openjdk-amd64` at java-8's JRE.
- **`java.security`** has its `*.disabledAlgorithms` lists blanked to re-enable
  the dead crypto the BMCs speak.
- **noVNC 1.4** is served by Sinatra; the WebSocket proxy uses **faye-websocket**
  and must call `Faye::WebSocket.load_adapter('thin')` (else thin writes a bogus
  second 101 and browsers reject it), and the app runs in **production** mode so
  `Rack::Lint` does not 500 the WebSocket upgrade.
- **One Xvnc display per BMC** gives each console total isolation.

## Security

- BMC credentials are **server-side only** (`.env`), never sent to the browser.
- **Put your BMCs on an isolated management VLAN.** IPMI 2.0 on this hardware
  generation has unfixable weaknesses (RAKP hash disclosure, cipher-0); network
  isolation is the correct mitigation and how it is meant to be deployed.
- noVNC currently has no VNC password (LAN + same-origin). A single platform
  login is the next planned addition.

## Roadmap

- Single platform login (one credential gating the whole app).
- Vendor-aware sensor naming so HP ambient/fan fields populate like Dell's.
- More nodes / BMC vendors.

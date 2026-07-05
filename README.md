# 🛡 Bastion

> **A hardened front for legacy iron.**
> One guarded entrance to lights-out management: **iLO2**, **iDRAC6**, a unified **IPMI dashboard**, and full **KVM consoles**, from any modern browser.

Bastion is a self-hosted control panel for out-of-band management of older
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
- **Serial / text consoles** in the browser (xterm.js): POST, boot loader, and a
  Linux login shell over the BMC's serial console, no Java at all. Two switchable
  transports per node, **SSH** (iLO2 `textcons` / iDRAC6 `console com2`) and
  **IPMI Serial-over-LAN**.
- **Virtual media**: mount ISOs into the console from a host folder.

## Architecture

```
                          Bastion
  ┌──────────────────────────────────────────────────────────────┐
  browser ──http:8088──▶  web  (Sinatra + Tailwind)
                          │  · IPMI dashboard + power   (ipmitool)
                          │  · serves noVNC 1.4 + xterm.js
                          │  · proxies the VNC + serial WebSockets
                          │
                          ├─ws /websockify/ilo──▶ engine :5901 ─┐  (KVM)
                          ├─ws /websockify/idrac─▶ engine :5902 ─┤
                          │                                      │
                          ├─ws /solws/<node> ─┐  (serial: a PTY  │
                          │                   │   in the web      │
                          │                   ▼   container)      │
                          │        ipmitool SOL / ssh textcons ───┤
        IPMI 2.0 (lanplus) ───────────────────────────────┐      │
                                                           ▼      ▼
                                                    iLO2 / iDRAC6 BMCs
  └──────────────────────────────────────────────────────────────┘
```

Two containers, one compose project:

- **`web`** (`ruby:3-slim`): the whole UI and the only thing you open in a
  browser. Sinatra + Tailwind, `ipmitool` for the dashboard and power actions,
  serves modern **noVNC 1.4** and **xterm.js**, and proxies both the VNC and the
  serial-console WebSockets in-process (faye-websocket) so there is a single
  origin and a single port. Serial consoles run as a PTY-hosted `ipmitool` or
  `ssh` process right here in `web` (no legacy stack needed for text).
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

Bastion contains all of that in the engine container so your daily driver
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
  **Console/Media -> Launch Virtual Console** (plug-in type Java). The Java
  security prompts (unverified signature, HTTPS cert, "remote locations") are
  pre-suppressed in the engine image, so the applet launches without clicking
  through dialogs.
- **Serial consoles** (`/serial/<node>`): a browser text terminal to the server's
  serial console, from POST all the way to a login shell, no Java. Each node with
  a BMC IP gets a **Serial** link on the dashboard. HP + Dell nodes offer an
  **SSH ⇄ SOL** toggle:
  - **SSH** — the BMC's own text console over its SSH CLI: iLO2 `textcons` (mirrors
    the VGA text buffer, repaints on attach) and iDRAC6 `console com2` (the COM2
    serial stream, with the serial history buffer replayed on connect).
  - **SOL** — raw IPMI Serial-over-LAN (`ipmitool sol activate`).

  To get a **login shell** (not just POST/firmware screens) the *server* needs a
  serial console: BIOS/RBSU serial redirection on **COM2** and a getty on
  `ttyS1` — on systemd, `console=ttyS1,115200n8` on the kernel command line spawns
  `serial-getty@ttyS1` automatically. See the serial-console notes in
  [docs/PLAN.md](docs/PLAN.md).
- **Virtual media**: drop `.iso` files into `./isos` (or repoint the volume in
  `docker-compose.yml`, e.g. `/mnt/c/Users/you/Downloads` on WSL2). They appear
  in the console's **Virtual Media / Image File** picker at `/isos`.

## Configuration (`.env`)

| Variable | Meaning |
|---|---|
| `ILO_IP` / `ILO_USER` / `ILO_PASS` | iLO2 management address and login |
| `IDRAC_IP` / `IDRAC_USER` / `IDRAC_PASS` | iDRAC6 management address and login |
| `PLATFORM_USER` / `PLATFORM_PASS` | local login for the web UI |
| `GITHUB_CLIENT_ID` / `_SECRET` / `GITHUB_ALLOWED_USERS` | GitHub OAuth login + allow-list |
| `SESSION_SECRET` | signs the session cookie (`openssl rand -hex 32`) |
| `TRUST_PROXY` | `1` when behind a TLS reverse proxy (see SECURITY.md) |
| `WEB_BIND` | host interface for `8088` (default `127.0.0.1`) |

Values are read literally (no quotes). BMC credentials live only server-side and
never reach the browser. Set a login (`PLATFORM_*` or GitHub) before exposing the
app: with neither configured it runs open.

## Tests

```bash
docker exec bmc-web bundle exec rspec
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
- **Java security prompts are pre-cleared** in the engine image so consoles launch
  without dialogs: `deployment.properties` sets `security.level=ALLOW_UNSIGNED`,
  `manifest.attributes.check=NONE` (the "uses resources from remote locations"
  ALACA check), `security.mixcode=DISABLE`, and `itw.ignorecertissues=true` (the
  HTTPS "cert cannot be verified" dialog); and a pre-seeded IcedTea trust store
  (`trusted.certs`, JKS, captured after ticking "Always trust this publisher") is
  baked in, with the runtime `security/` dir on the `icedtea-trust` volume so new
  trust decisions persist across rebuilds.
- **noVNC 1.4** is served by Sinatra; the WebSocket proxy uses **faye-websocket**
  in `rack.hijack` mode under **puma** with a raw `TCPSocket` bridge (no
  EventMachine), and the app runs in **production** mode so `Rack::Lint` does not
  500 the WebSocket upgrade.
- **Serial consoles** bridge a browser xterm.js to a PTY-hosted console process in
  the `web` container over `ws /solws/<node>` (auth-gated). SSH mode logs into the
  BMC CLI and auto-types its console command (`textcons` at `hpiLO->`,
  `console -h com2` at `/admin1->`) with the iLO/iDRAC's legacy SSH crypto
  re-enabled via `ssh -o` overrides; SOL mode runs `ipmitool sol activate` with a
  deactivate-first/deactivate-on-close guard. One session per node, new connection
  takes over.
- **One Xvnc display per BMC** gives each console total isolation.

## Security

Full posture, accepted risks, and hardening steps are in **[SECURITY.md](SECURITY.md)**.
In brief:

- **Authenticated front door.** Every route is gated by GitHub OAuth (allow-list)
  and/or a local login (constant-time compare). The console WebSocket is gated too.
- **BMC credentials are server-side only**, never sent to the browser. They live
  in `.env` and the `servers-data` volume (`servers.json`, plaintext, same trust
  level as `.env`), both outside git and the image.
- **No shell for IPMI** (argv array, injection-safe); **auto-escaped output**
  (Erubi) mitigates XSS; **`SameSite=Lax`** cookies are the CSRF mitigation.
- **Loopback by default:** `8088` binds to `127.0.0.1`; front it with a TLS
  reverse proxy (set `TRUST_PROXY=1`). See SECURITY.md for the NPM recipe
  (Websockets ON, long read timeout, OAuth callback URL).
- **Put your BMCs on an isolated management VLAN.** IPMI 2.0 on this hardware has
  unfixable weaknesses; network isolation is the intended mitigation.
- **CI** runs RSpec + blocking `bundler-audit` (dependency CVEs) on every push.

## Roadmap

- Vendor-aware sensor naming so HP ambient/fan fields populate like Dell's.
- More nodes / BMC vendors.
- Dynamic KVM consoles for CRUD-added servers (currently the two seeded consoles
  are the wired ones).

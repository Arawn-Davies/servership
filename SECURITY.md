# Security

This app drives out-of-band management of legacy BMCs (iLO2, iDRAC6) that
themselves have unfixable weaknesses. The design goal is to confine that legacy
to a container and put a modern, authenticated front door in front of it. This
document describes the posture, the accepted risks, and how to deploy it safely.

## Threat model

- **In scope:** a browser client on your network reaching the web UI; the app
  reaching BMCs over IPMI and VNC; credential handling; the auth front door.
- **Out of scope:** the BMC firmware itself (IPMI 2.0 on this hardware
  generation has known, vendor-abandoned flaws), and physical access to the host.
- **Trust boundary:** the host running Docker and the management VLAN are
  trusted. The general LAN and the internet are not.

## The front door (authentication)

Every route except `/login`, `/logout`, and `/auth/*` is gated by a `before`
filter (`web/app.rb`). Two methods, either or both:

- **GitHub OAuth** via OmniAuth, restricted to a case-insensitive allow-list
  (`GITHUB_ALLOWED_USERS`). A valid GitHub login not on the list is rejected 403.
- **Local login** (`PLATFORM_USER` / `PLATFORM_PASS`), compared with
  `Rack::Utils.secure_compare` (constant-time, resists timing attacks).

> **Important:** auth is only enforced when at least one method is configured.
> If both GitHub and `PLATFORM_USER` are left blank the app runs **open**. Always
> set local creds or GitHub before exposing it anywhere. This is intentional for
> first-boot on a trusted workstation, but it is a foot-gun worth calling out.

The noVNC WebSocket proxy is gated too: `config.ru`'s bridge returns `401` unless
the Rack session is authenticated, so the console stream cannot be reached
without a login even though it lives at a different mount point.

## Sessions

- `Rack::Session::Cookie`, signed with `SESSION_SECRET`. If that env var is unset
  a random 64-hex secret is generated per boot, which is safe but invalidates all
  sessions on every restart. **Set `SESSION_SECRET`** in production
  (`openssl rand -hex 32`).
- `SameSite=Lax` and a 12-hour expiry.
- `Secure` is set on the cookie when `TRUST_PROXY=1` (see below). Do not hardcode
  it: a `Secure` cookie over plain HTTP would silently break login.

## CSRF posture

There is no CSRF token. The mitigation is the `SameSite=Lax` session cookie,
which browsers withhold from cross-site POSTs, so a third-party page cannot forge
an authenticated `POST /power`, `POST /servers`, or a delete. This is adequate
for a single-origin LAN tool behind a login. If this app is ever exposed more
broadly, add a proper CSRF token (e.g. `Rack::Protection::AuthenticityToken`).

## Credential handling

- **BMC credentials never reach the browser.** The dashboard renders no
  passwords; the edit form leaves the password field blank and a blank submit
  keeps the stored value (`Store.save`).
- Credentials live server-side in two places, both **outside git and the image**:
  - `.env` (gitignored) seeds the two wired consoles on first run.
  - `/data/servers.json` on the `servers-data` Docker volume holds the CRUD
    server list, including BMC passwords **in plaintext**.
- **Accepted risk:** `servers.json` is plaintext at the same trust level as
  `.env`. Anyone with host/root access or access to the Docker volume can read
  BMC passwords. This is acceptable because the host is already the trust anchor
  (it has `.env` and can talk to the BMCs regardless). It is **not** encrypted at
  rest. Do not put the volume on shared/untrusted storage.

## Command execution

IPMI is invoked through `IO.popen` with an **argument array**, never a shell
string (`web/app.rb`, `ipmi`). A password or field containing `;`, `!`, `$`, or
spaces is passed verbatim as one argv element and cannot inject a command.

## Output encoding (XSS)

Views render through Erubi with `escape_html: true`, so `<%= %>` auto-escapes and
only the few deliberate `<%== %>` sites emit raw HTML. The server-edit UI passes
values to JavaScript via escaped `data-*` attributes read from `dataset` (and
never includes the password), avoiding an inline-JSON injection sink.

## Action allow-lists

`POST /power`, `POST /console/:key/:action`, and the console key itself are
validated against server-side allow-list maps; anything unknown returns `400`/`404`
before touching a BMC. The client-side `confirm()` dialogs on destructive actions
are UX guards, not a security control.

## Network exposure

- The container's `8088` binds to **`127.0.0.1` by default** (`WEB_BIND`), so the
  app is not reachable across the LAN. A reverse proxy on the host fronts it.
- **Put your BMCs on an isolated management VLAN.** IPMI 2.0 on this hardware has
  unfixable weaknesses (RAKP hash disclosure, cipher-zero). Network isolation is
  the correct and intended mitigation.
- The legacy KVM engine (dead TLS/ciphers, NPAPI Java, expired-cert acceptance)
  is confined to the `console` container and publishes **nothing** to the host;
  it is reachable only by `web` over the compose network. The dead crypto is used
  only to talk *outbound* to the BMCs, never exposed to clients.

## Running behind TLS (reverse proxy)

The app terminates plain HTTP; put TLS in front with a reverse proxy such as
Nginx Proxy Manager (NPM). App-side setup:

1. In `.env`: set `TRUST_PROXY=1` and keep `WEB_BIND=127.0.0.1`.
2. `TRUST_PROXY=1` mounts the `TrustProxy` middleware (`config.ru`), which reads
   `X-Forwarded-Proto`/`X-Forwarded-Port` and normalises `rack.url_scheme` so
   OAuth `redirect_uri`s and absolute URLs are `https://`, and it flips the
   session cookie to `Secure`. **Only enable it when the app is reached solely
   through a proxy you control** that sets those headers; otherwise a client could
   spoof `X-Forwarded-Proto`.
3. Proxy-host settings (NPM or equivalent):
   - Forward to `127.0.0.1:8088`.
   - **Websockets Support: ON.** Mandatory, or the noVNC console connects then
     drops.
   - Advanced: `proxy_read_timeout 86400s;` so an idle KVM stream is not cut at
     the default 60s.
   - Let's Encrypt cert + Force SSL + HTTP/2.
   - If using GitHub OAuth, set the OAuth app callback to
     `https://<your-domain>/auth/github/callback`.
4. Harden the proxy itself (its admin UI on a separate port/network, an Access
   List or IP allow-list in front of the app). That is the proxy's job, not this
   app's.

## Supply chain

CI (`.github/workflows/ci.yml`) runs on every push/PR:

- **RSpec** (routing, power-action allow-list, launch trigger, CRUD, noVNC
  embedding; IPMI stubbed so tests never touch a real BMC).
- **bundler-audit** against the gem lockfile: **blocking**, fails the build on a
  known CVE.
- **Brakeman**: best-effort and non-blocking (it is Rails-oriented and misses
  Sinatra-specific issues), kept for signal only.

## Reporting

This is a personal/self-hosted project. Open an issue at
`github.com/Arawn-Davies/servership` for security concerns.

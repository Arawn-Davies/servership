# Servership - implementation plan (next up)

Two features to build next. Written before a WSL2 RAM bump so we can resume
cleanly. No em-dashes anywhere.

## Resume after `wsl --shutdown`
1. Docker Desktop should auto-start; if not, start it.
2. `cd ~/src/megamigration/bmc-console && docker compose up -d` (images already
   built; no `--build` needed unless code changed).
3. Verify: `curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8088/`
   should be 200; `docker exec bmc-web bundle exec rspec` should be 8/8.
4. Open http://localhost:8088/ in Windows Firefox.

---

## Feature 1: single platform login

One credential gates the whole app. BMC creds already never reach the browser
(server-side `.env`); this just stops an unauthenticated LAN user from opening
the UI, hitting `/power`, or opening a console.

### Config
- Add to `.env` and `.env.example`: `PLATFORM_USER`, `PLATFORM_PASS`, and
  `SESSION_SECRET` (long random hex).

### Web app (`web/app.rb`, class `BMC`)
- Enable sessions with the shared secret:
  `use Rack::Session::Cookie, secret: ENV['SESSION_SECRET'], same_site: :lax`
  (mounted in `config.ru` so the WS proxy sees it too, see below).
- Routes:
  - `GET /login` -> Tailwind login form (branded, matches the dark theme).
  - `POST /login` -> compare with `Rack::Utils.secure_compare` (constant-time)
    against `PLATFORM_USER`/`PLATFORM_PASS`; on success set
    `session[:auth] = true` and redirect to `/`; on failure re-render with an
    error.
  - `GET /logout` -> `session.clear`, redirect to `/login`.
- `before` filter: unless `session[:auth]` or `request.path_info == '/login'`
  (and allow static `/novnc/*` assets), redirect to `/login`.

### WebSocket proxy (`web/config.ru`)
- The proxy is a separate Rack app, so protect it too or someone could open a
  raw console stream. Mount the SAME `Rack::Session::Cookie` middleware around
  BOTH `map` targets in `config.ru`, then in `ws_proxy` check
  `env['rack.session'] && env['rack.session'][:auth]`; if not authed, return
  `[401, {}, ['unauthorized']]` before the faye upgrade.
- Because both apps share one session middleware + secret, the cookie set by
  Sinatra login is readable by the proxy.

### Login page
- Minimal centered card, `⚓ Servership`, one user + password field, submit.
  Reuse the dark Tailwind look from `layout.erb`.

### Tests (`web/spec/app_spec.rb`)
- Unauthenticated `GET /dashboard` (and `/`, `/console/ilo`, `POST /power`)
  redirects to `/login` (302).
- After `POST /login` with correct creds, protected routes return 200.
- Wrong creds -> stays on login (no session).
- Helper to log in within Rack::Test (post /login, keep the cookie jar).

### Gotchas
- Set `SESSION_SECRET` in `.env` (>= 64 hex chars) or sessions reset on every
  restart.
- Keep `/novnc/*` static assets reachable pre-auth OR the login page is fine
  since it needs no noVNC; simplest is to only gate the app routes and the WS
  proxy, and leave the static noVNC files ungated (they are inert without a
  valid WS).

---

## Feature 2: vendor-aware sensor naming

HP iLO2 and Dell iDRAC6 name their IPMI SDR entries differently, so the
dashboard currently shows `?` ambient and `0` fans for the HP box while Dell is
correct. Make the parsing vendor-aware and fall back to `n/a` where a vendor
genuinely does not expose a metric over IPMI.

### Step 0: learn the real HP names (diagnostic first, do NOT guess)
Run against the iLO and capture actual sensor names before coding:
```
docker exec bmc-web ipmitool -I lanplus -H 10.0.0.245 -U adavies -P "$ILO_PASS" sdr
docker exec bmc-web ipmitool -I lanplus -H 10.0.0.245 -U adavies -P "$ILO_PASS" sdr type temperature
docker exec bmc-web ipmitool -I lanplus -H 10.0.0.245 -U adavies -P "$ILO_PASS" sdr type fan
```
Note: some iLO2 firmware does not expose fan RPM or wattage over IPMI at all
(only via the web UI). If so, show `n/a`, do not fake a 0.

### Implementation (`web/app.rb`)
- Add a `vendor` field per node in `NODES` (`'hp'` for ilo, `'dell'` for idrac).
- Replace the current single-pattern `ambient`/`fans_ok`/watts logic with
  vendor-aware extractors, driven by the real names found in Step 0. Likely:
  - ambient: dell `/ambient|inlet/i`; hp whatever Step 0 shows (often `Temp 1`
    or `01-Inlet`), else first temperature reading.
  - fans: count `/fan/i` rows reporting RPM with an ok-ish status; `n/a` if the
    vendor exposes none.
  - watts: dell `System Level`/any `Watts`; hp `Power Meter`/`Present Power`,
    else `n/a`.
- Keep it data-driven: a small `SENSOR_HINTS = { 'hp' => {...}, 'dell' => {...} }`
  map of regexes, so adding a third vendor later is trivial.

### Dashboard (`web/views/dashboard.erb`)
- Show `n/a` (muted) instead of `?`/`0` when a metric is genuinely unavailable,
  so an HP box that hides fans over IPMI reads honestly.

### Tests
- Add an HP-style stub (sensor names from Step 0) and assert ambient + fan count
  parse correctly, plus a `n/a` case.

---

## Order
Do Feature 1 first (self-contained, testable, higher value), then Feature 2
(needs the Step 0 diagnostic against the live iLO). Both keep tests green.

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

## Feature 1: platform login (GitHub SSO + local fallback)

Gate the whole app so an unauthenticated LAN user cannot open the UI, hit
`/power`, or open a console. Two ways in, both landing on the same
`session[:auth] = true`:
- **GitHub SSO (primary):** "Sign in with GitHub", restricted to an allowlist of
  GitHub usernames (just you). No shared password to leak.
- **Local credential (fallback):** one `PLATFORM_USER`/`PLATFORM_PASS`, for when
  the box sits on an isolated mgmt VLAN with no internet (GitHub OAuth needs both
  the browser AND the server to reach github.com). Omit the vars to disable it.

BMC creds already never reach the browser (server-side `.env`); this is purely
the front door.

### Config (`.env` / `.env.example`)
- `SESSION_SECRET` (long random hex; sessions reset without it).
- GitHub SSO: `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`,
  `GITHUB_ALLOWED_USERS` (comma-separated logins, e.g. `Arawn-Davies`).
- Local fallback (optional): `PLATFORM_USER`, `PLATFORM_PASS`.
- Register a GitHub OAuth App (github.com -> Settings -> Developer settings ->
  OAuth Apps). Authorization callback URL:
  `http://localhost:8088/auth/github/callback`. One callback per app, so use the
  exact host:port you browse from (or a stable hostname).

### Gems (`web/Gemfile`)
- `omniauth`, `omniauth-github`. omniauth 2.x requires a POST request phase with
  CSRF; use rack-protection's `AuthenticityToken` (Sinatra bundles
  rack-protection) or `omniauth-rack_csrf`.

### Web app (`web/app.rb`, class `BMC`)
- Session via a shared `Rack::Session::Cookie` mounted in `config.ru` (below),
  so both the app and the WS proxy read it.
- Routes:
  - `GET /login` -> branded page: primary "Sign in with GitHub" (POST form to
    `/auth/github`) and, if `PLATFORM_USER` is set, a local user/pass form.
  - `GET /auth/github/callback` (OmniAuth) -> read
    `request.env['omniauth.auth']`; check `info.nickname` (the GitHub login) is
    in `GITHUB_ALLOWED_USERS`. If yes: `session[:auth]=true`,
    `session[:user]=login`, redirect `/`. If not: 403.
  - `GET /auth/failure` -> back to `/login` with an error.
  - `POST /login` (local) -> `Rack::Utils.secure_compare` vs PLATFORM creds ->
    `session[:auth]=true`; else re-render.
  - `GET /logout` -> `session.clear`, redirect `/login`.
- `before` filter: unless `session[:auth]`, or path is `/login` or under
  `/auth/`, redirect to `/login`.
- Header shows `session[:user]` + a logout link once authed.

### OmniAuth + session middleware (`web/config.ru`)
- Before the `map` blocks (so it wraps BOTH the Sinatra app and the WS proxy):
  ```
  use Rack::Session::Cookie, secret: ENV['SESSION_SECRET'], same_site: :lax
  use OmniAuth::Builder do
    provider :github, ENV['GITHUB_CLIENT_ID'], ENV['GITHUB_CLIENT_SECRET'],
             scope: 'read:user'
  end
  ```

### WebSocket proxy (`web/config.ru`)
- Same shared session wraps it, so in `ws_proxy` check
  `env['rack.session'] && env['rack.session'][:auth]`; if not authed, return
  `[401, {}, ['unauthorized']]` before the faye upgrade. Stops a raw console
  stream being opened unauthenticated.

### Login page
- Centered dark Tailwind card, `⚓ Servership`, big "Sign in with GitHub" button,
  optional local user/pass under a divider. Reuse the look from `layout.erb`.

### Tests (`web/spec/app_spec.rb`)
- OmniAuth test mode: `OmniAuth.config.test_mode = true` and
  `OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(info: { nickname: 'Arawn-Davies' })`.
- Unauthenticated protected routes (`/`, `/dashboard`, `/console/ilo`,
  `POST /power`) -> 302 to `/login`.
- Callback with an ALLOWED nickname -> session set, `/dashboard` 200.
- Callback with a NON-allowed nickname -> 403, no session.
- Local login (if configured): right creds pass, wrong creds stay on login.

### Gotchas
- `SESSION_SECRET` >= 64 hex chars in `.env`, or sessions reset each restart.
- One GitHub OAuth callback URL per app: browsing from multiple hosts/ports means
  separate OAuth apps or a standardised URL.
- Isolated mgmt VLAN = no internet = GitHub OAuth cannot work; that is exactly
  why the local `PLATFORM_USER`/`PLATFORM_PASS` fallback exists.
- Leave `/novnc/*` static assets ungated (inert without a valid, authed WS).

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

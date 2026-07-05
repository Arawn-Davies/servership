# Bastion - implementation plan (next up)

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
- Centered dark Tailwind card, `🛡 Bastion`, big "Sign in with GitHub" button,
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

## Feature 3: autologin to the BMC web UIs

Reuse the `.env` creds so no password typing. Only the loosened Firefoxes can
reach the BMCs' dead TLS (curl fails with exit 59 / cipher errors), so this must
run in the browser, not a script.

### Approach
The launch scripts (`ilo2`, `idrac6`) already run in the engine with the creds in
env. Instead of opening Firefox at the raw BMC URL, have them **write a tiny
per-node `autologin.html` to a temp file and open that**. The page holds an
auto-submitting form that POSTs the creds to the BMC login endpoint; the browser
lands authenticated. Self-contained in the engine, no web-container or auth
dependency. Cross-origin form POST is allowed; the BMC sets its own session
cookie and the browser navigates in.

```
<body onload="document.forms[0].submit()">
  <form method="post" action="https://<IP>/<login-endpoint>">
    <input type="hidden" name="<user-field>"  value="<ILO_USER>">
    <input type="hidden" name="<pass-field>"  value="<ILO_PASS>">
  </form>
</body>
```

### Investigation needed first (curl is blocked by the dead TLS)
- **iLO2 (10.0.0.245):** open the login page in the engine's FF52, View Source,
  and read the `<form>` action + the username/password `<input name=...>`. iLO2
  firmware varies; if the login is JS-built with a nonce/challenge (not a plain
  form POST) a static form will not work and we fall back to autofill.
- **iDRAC6 (10.0.0.81):** endpoint is known: `POST /data/login` with
  `user=<...>&password=<...>`, but it returns XML (`authResult`), not the UI. So:
  submit to `/data/login` in a hidden iframe, then on load set
  `window.location = 'https://<IP>/'` once the session cookie is set.

### Caveats
- Creds sit in a local `file://` HTML in the engine container (root-only,
  ephemeral). Fine; they are already in the engine's env.
- Per-firmware field names; verify each BMC once and hardcode.
- If a BMC refuses a static-form login (challenge/nonce), fall back to seeding
  Firefox saved logins or just prefill (username is already remembered; only the
  password field is empty).

---

## Order
1. Feature 1 (login/SSO): self-contained, testable, highest value.
2. Feature 3 (BMC autologin): quick win, needs the iLO2 view-source step.
3. Feature 2 (vendor sensors): needs the Step 0 `ipmitool sdr` diagnostic.
All three keep tests green.

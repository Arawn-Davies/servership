# OWASP ZAP automation plan (GitHub Actions)

Automated DAST (dynamic scanning) of the web UI in CI. This is the plan; the
files it describes are not committed yet.

## Guiding constraints (read first)

1. **Never scan against real BMCs.** ZAP's active scanner sends crafted requests
   to every discovered form and endpoint. This app has endpoints that *power off
   servers* (`POST /power` with `off`/`cycle`/`reset`), *delete data*
   (`POST /servers/:id/delete`), and *kill consoles* (`POST /console/:key/exit`).
   The scan MUST run against an **ephemeral instance with fake BMC IPs** (IPMI to
   a dead IP just times out to `unreachable`, harmless) and a throwaway volume.
2. **Exclude the destructive + binary paths from scope** as belt-and-braces, even
   on the ephemeral instance, so scan time is not wasted and the store is not
   churned: `/power`, `/servers`, `/servers/*/delete`, `/console/*/exit`,
   `/websockify/*`, `/novnc/*`.
3. **Authenticate.** Most routes are behind login. Scan with local auth
   (`PLATFORM_USER`/`PLATFORM_PASS`), configured via ZAP form-based auth. GitHub
   OAuth cannot be driven headlessly, so it stays disabled for the scan.

## Two-tier strategy

| Tier | Trigger | Scanner | Blocking | Purpose |
|---|---|---|---|---|
| **Baseline** | every PR + push | `zaproxy/action-baseline` (spider + passive rules, no attacks) | fail on High | fast, safe, catches headers/cookies/info-leak regressions |
| **Full** | nightly schedule + manual dispatch | `zaproxy/action-full-scan` via Automation Framework (spider + active attacks) | fail on High, report Medium | deep authenticated active scan against the ephemeral stack |

Baseline is non-destructive and finishes in ~1 to 2 minutes, so it fits PR CI.
The active scan is slower and noisier, so it runs on a schedule against a
purpose-built ephemeral target, not on every PR.

## Bringing up the scan target

A scan-only compose override with fake creds and no real BMCs:

- `.env.scan`: `PLATFORM_USER=zap`, `PLATFORM_PASS=<random>`, `SESSION_SECRET=<fixed>`,
  `ILO_IP`/`IDRAC_IP` pointed at `192.0.2.x` (TEST-NET, guaranteed dead),
  `TRUST_PROXY=0`, `WEB_BIND=0.0.0.0` (CI-only, so the ZAP container can reach it),
  GitHub vars blank.
- Job steps: `docker compose --env-file .env.scan up -d --build`, wait for
  `http://localhost:8088/login` to return 200, run ZAP, tear down.

Because the volume is ephemeral in CI, the seeded `servers.json` is disposable,
so even if a delete slips through scope it harms nothing.

## Authentication (ZAP Automation Framework)

Form-based auth in the AF plan (`af-plan.yaml`):

- **authentication:** method `form`, `loginPageUrl: /login`,
  `loginRequestUrl: /login`, body `user={%username%}&pass={%password%}`.
- **session management:** `cookie` (the app uses `Rack::Session::Cookie`).
- **verification:** logged-in when the response contains `Log out`; logged-out
  when it redirects to `/login`. Set `loggedInRegex`/`loggedOutRegex` accordingly.
- **user:** `zap` with the password from `.env.scan`.
- **excludePaths:** `/logout`, `/auth/.*` (so the spider/scanner does not log
  itself out or wander into OAuth), plus the destructive/binary paths from
  constraint 2.

The AF plan runs jobs in order: `spider` -> `passiveScan-wait` ->
`activeScan` -> `report`.

## Tuning false positives

The app is meant to sit **behind a TLS reverse proxy** that adds HSTS/CSP and
handles TLS, so ZAP will flag things the proxy is responsible for. Suppress or
downgrade these in `.zap/rules.tsv` (documented, not blanket-ignored):

- Missing `Strict-Transport-Security` / CSP: added by NPM in prod, expected
  absent when scanning the app directly. **Downgrade to WARN**, note in the row.
- `Content-Security-Policy` from the Tailwind Play CDN (`cdn.tailwindcss.com`):
  a known dev-time inline-script pattern; track separately.
- Anything genuinely actionable (cookie flags, verb tampering, injection,
  reflected params) stays at **FAIL**.

Keep the rules file small and commented so a suppression is never mistaken for a
clean result.

## Gating and reporting

- **Fail the job on any High-risk alert**; surface Medium as warnings in the job
  summary.
- Upload the ZAP **HTML + JSON report** as a workflow artifact every run.
- Optionally convert the JSON to **SARIF** and upload to GitHub code scanning so
  alerts show inline on PRs (Security tab). Nice-to-have, second iteration.

## Files this plan will add

```
.github/workflows/zap-baseline.yml   # PR/push, passive baseline
.github/workflows/zap-full.yml       # nightly + dispatch, authenticated active
.zap/af-plan.yaml                    # Automation Framework: context, auth, jobs
.zap/rules.tsv                       # alert threshold tuning (commented)
.env.scan                            # ephemeral scan creds, fake BMC IPs (gitignored? no: no real secrets)
docker-compose.scan.yml              # optional override (WEB_BIND, ephemeral volume)
```

## Rollout order

1. **Baseline workflow first** (passive, safe, no auth needed to prove the
   pipeline). Get a clean run, tune `rules.tsv`.
2. **Add the ephemeral stack + AF auth**, verify ZAP is actually logged in
   (report should show authenticated pages, not the login wall).
3. **Enable the active scan** on a schedule once scope exclusions are confirmed,
   so a misconfigured scope can never hammer a real BMC.
4. **SARIF upload** last, once alert volume is understood.

## Sketch: baseline workflow

```yaml
name: ZAP Baseline
on:
  pull_request:
  push:
    branches: [main]
jobs:
  zap:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Bring up ephemeral app (fake BMCs)
        run: |
          cp .env.scan .env
          docker compose up -d --build
          for i in $(seq 1 30); do curl -sf http://localhost:8088/login && break; sleep 2; done
      - name: ZAP baseline
        uses: zaproxy/action-baseline@v0.12.0
        with:
          target: http://localhost:8088
          rules_file_name: .zap/rules.tsv
          cmd_options: '-a'      # include the alpha passive rules
          fail_action: true      # fail on High
      - name: Tear down
        if: always()
        run: docker compose down -v
```

The full/active workflow is the same shape but swaps `action-baseline` for
`action-full-scan` with `-z "-configfile /zap/wrk/af-plan.yaml"` (or the AF
action) so the authenticated context and scope exclusions apply, and runs on
`schedule:` + `workflow_dispatch:` instead of on every PR.

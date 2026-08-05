# 1G VPS Deployment

> Deprecated for production. The production host is 2C2G and must use
> `deploy/deploy.sh` with the 2C2G resource baseline. Do not run
> `deploy/deploy-1g.sh` for a production release. This document remains only
> for recovery and historical configuration reference.

This deployment profile is for a 1 vCPU / 1 GB RAM server. It runs Caddy,
AI Gateway, PostgreSQL, and Redis on one host with conservative memory limits.
The default container memory caps total about 704 MB, leaving room for the OS,
Docker, filesystem cache, and temporary spikes.
Docker logs are capped at 10 MB x 3 files per container so a small VPS disk does
not get filled by noisy stdout/stderr logs. The gateway application's own file
logs are also capped at 10 MB x 3 backups in this profile.

## Required inputs

- `SSH_TARGET`: SSH target, for example `root@203.0.113.10` or
  `dhy@203.0.113.10` when that user can run `sudo`
- `DOMAIN`: full hostname, for example `api.example.com`
- `CF_API_TOKEN`: Cloudflare API token with `Zone:Read` and `DNS:Edit`

`DOMAIN` must use normal DNS labels: no empty labels, no leading or trailing
hyphens in a label, and an alphabetic top-level domain.

If both Japan and Hong Kong VPS instances are available, fill `JP_*` and `HK_*`
values in `deploy/deploy-1g.env.local`, then set `TARGET_REGION=auto`, `jp`, or
`hk`. In deploy/preflight mode, `auto` tries Japan first, then Hong Kong, and
uses the first server that passes remote preflight. Leave `TARGET_REGION` empty
to use `SSH_TARGET` directly.

Use DNS-only mode for the first deploy. The script sets `PROXIED=false` by default
so Caddy can obtain a normal Let's Encrypt certificate over HTTP-01.
After the certificate is issued, you can enable Cloudflare proxy separately if
you need it.

Use `SSH_KEY=/path/to/key` for key-based SSH. If you only have a password,
set `SSH_PASSWORD=...`; this requires `sshpass` on the local machine.
`SSH_PASS=...` is accepted as an alias for `SSH_PASSWORD` because some local ops
skills use that variable name. Use exactly one SSH auth method. The deploy,
check, restore, and doctor scripts reject configurations that set both `SSH_KEY`
and password auth, and they fail early if `SSH_KEY` points to a missing file.
The deploy script accepts non-root SSH users when `sudo` works. `REMOTE_SUDO`
defaults to `auto`: root SSH runs directly, non-root SSH runs privileged remote
steps through sudo. If sudo needs a different password, set `SUDO_PASSWORD`.
When it is empty, the script tries the SSH password as the sudo password.
`SSH_CONNECT_TIMEOUT` defaults to 15 seconds so a wrong IP or closed SSH port
fails quickly.

1G deployment is cloud-only. The local machine only creates and uploads a
source archive, runs SSH orchestration, and calls Cloudflare. Docker install,
Caddyfile validation, Compose validation, image build, and service startup all
happen on the VPS. `BUILD_STRATEGY=remote` is kept as a compatibility value in
env files; any other value is rejected so the script cannot silently fall back
to a local Docker build.
For 1 GB servers, the Docker build stage defaults to
`BUILD_NODE_OPTIONS=--max-old-space-size=1280` and `BUILD_GOMAXPROCS=1`. The
remote build disables BuildKit so frontend and backend stages do not compete for
memory on a 1C1G VPS. Backend compilation also forces package parallelism to one,
sets `GOMEMLIMIT=640MiB`, lowers `GOGC`, and disables Go inlining because the
generated `ent` package otherwise spends minutes swapping on 1 GB RAM. The remote
image build runs Vite directly instead of
`vue-tsc -b && vite build`. `vite-plugin-checker` is only enabled for the Vite
dev server, so production `vite build` does not spawn `vue-tsc --noEmit`; run
frontend type checking in CI or locally, not on the 1G production box.

`ADMIN_EMAIL` must be a valid email address. If `ADMIN_PASSWORD` is omitted, the
deploy script generates one and prints it after the HTTPS health check passes.
If `ACME_EMAIL` is set, it must be a valid email address. The deploy script
writes it into the uploaded Caddyfile as the ACME account email. Leave it empty
if you do not want to set one.
Custom values written into the remote `.env` file, such as `ADMIN_PASSWORD`,
`POSTGRES_PASSWORD`, `JWT_SECRET`, `TOTP_ENCRYPTION_KEY`, `ACME_EMAIL`, and
`REDIS_PASSWORD`, must be single-line safe tokens. Use letters, numbers, dot,
underscore, at, colon, slash, plus, equals, comma, question mark, ampersand,
percent, or dash. Spaces, `$`, quotes, and newlines are rejected because they
make Docker Compose env parsing ambiguous.

`SWAP_SIZE` controls the swapfile created during remote bootstrap and must use
an `M` or `G` suffix, for example `2048M` or `2G`. `MIN_FREE_KB` and
`MIN_DOCKER_FREE_KB` tune the remote preflight disk-space gates for the deploy
directory and Docker data directory. Keep the defaults unless the VPS disk is
known to be smaller; lowering them can make deployment start and then fail later
when the image, database, logs, or Caddy data consume disk.
`DOCKER_INSTALL_METHOD` controls remote Docker installation and defaults to
`auto`: try the OS package manager first, then fall back to `get.docker.com`.
Set it to `package` or `get-docker` only when debugging a provider image.

The script can open `ufw` or `firewalld` ports on the server, but it cannot open
Huana Cloud's provider-side firewall/security group without provider
credentials. TCP `80` and `443` must be reachable from the internet for HTTPS.

## Deploy

Copy the environment template and fill real values:

```bash
cd <repo>
cp deploy/deploy-1g.env.example deploy/deploy-1g.env.local
```

For Huana Cloud Japan/Hong Kong servers, use the non-secret template and fill
the target IPs from your private ops notes or local SSH skill:

```bash
cd <repo>
cp deploy/deploy-1g.huana.env.example deploy/deploy-1g.env.local
```

Or generate that local file without writing SSH or Cloudflare secrets into it.
Pass the target values in the shell or fill them after generation:

```bash
cd <repo>
DOMAIN=api.example.com deploy/init-huana-1g-env.sh
```

For the Huana Japan/Hong Kong servers, the shortest safe deploy path is the
wrapper. It creates the local env file when needed, refuses persisted SSH or
Cloudflare secrets, runs readiness checks, remote preflight, deploy, and the
final health check:

```bash
SSH_PASS='<server-password>' CF_API_TOKEN='<cloudflare-token>' \
  DOMAIN=api.example.com deploy/huana-1g-deploy.sh
```

Readiness-only check, with no SSH connection and no Cloudflare mutation:

```bash
SSH_PASS='<server-password>' CF_API_TOKEN='<cloudflare-token>' \
  ENV_FILE=deploy/deploy-1g.env.local deploy/ready-1g.sh
```

Completion verification after deployment:

```bash
SSH_PASS='<server-password>' CF_API_TOKEN='<cloudflare-token>' \
  ENV_FILE=deploy/deploy-1g.env.local deploy/verify-live-1g.sh
```

Write a local, non-secret verification artifact:

```bash
SSH_PASS='<server-password>' CF_API_TOKEN='<cloudflare-token>' \
  LIVE_REPORT_FILE=deploy/live-1g-report.json \
  ENV_FILE=deploy/deploy-1g.env.local deploy/verify-live-1g.sh
```

Audit completion from local evidence, without SSH, Cloudflare, or local Docker:

```bash
ENV_FILE=deploy/deploy-1g.env.local \
  LIVE_REPORT_FILE=deploy/live-1g-report.json \
  deploy/audit-1g-completion.sh
```

Or generate the live report and audit it in one command:

```bash
SSH_PASS='<server-password>' CF_API_TOKEN='<cloudflare-token>' \
  RUN_VERIFY=true LIVE_REPORT_FILE=deploy/live-1g-report.json \
  ENV_FILE=deploy/deploy-1g.env.local deploy/audit-1g-completion.sh
```

`verify-live-1g.sh` proves the pieces that matter for handoff: the env is
deployable, Cloudflare has a single matching `A` record with the expected
proxied state, the remote Compose stack is reachable, and
`https://$DOMAIN/health`, `/login`, and the built frontend asset load.
`audit-1g-completion.sh` is the final local gate: without a restrictive,
non-secret `deploy-1g.env.local` and a live report containing all five checks
above, the deployment is not considered complete.

Or run the underlying deploy script directly:

```bash
SSH_PASS='<server-password>' CF_API_TOKEN='<cloudflare-token>' \
  ENV_FILE=deploy/deploy-1g.env.local deploy/deploy-1g.sh
```

Values passed directly on the command line override values from `ENV_FILE`.
This also applies when `TARGET_REGION` is set: explicit `SSH_TARGET`,
`SSH_PORT`, `SSH_KEY`, `SSH_PASSWORD` or `SSH_PASS`, and `TARGET_IP` values win
over matching `JP_*` or `HK_*` values loaded from the env file.

Useful modes:

```bash
SSH_PASS='<server-password>' CF_API_TOKEN='<cloudflare-token>' \
  ENV_FILE=deploy/deploy-1g.env.local deploy/doctor-1g.sh
SSH_PASS='<server-password>' DEPLOY_MODE=build \
  ENV_FILE=deploy/deploy-1g.env.local deploy/deploy-1g.sh
SSH_PASS='<server-password>' DEPLOY_MODE=preflight \
  ENV_FILE=deploy/deploy-1g.env.local deploy/deploy-1g.sh
SSH_PASS='<server-password>' CF_API_TOKEN='<cloudflare-token>' DEPLOY_MODE=deploy \
  ENV_FILE=deploy/deploy-1g.env.local deploy/deploy-1g.sh
```

Switch target without editing the env file:

```bash
TARGET_REGION=jp ENV_FILE=deploy/deploy-1g.env.local deploy/doctor-1g.sh
TARGET_REGION=hk DEPLOY_MODE=preflight ENV_FILE=deploy/deploy-1g.env.local deploy/deploy-1g.sh
TARGET_REGION=auto DEPLOY_MODE=deploy ENV_FILE=deploy/deploy-1g.env.local deploy/deploy-1g.sh
```

Run `deploy/doctor-1g.sh` first. It does not connect to the server or change
Cloudflare. It checks local non-Docker tooling and obvious placeholder values;
Compose and Caddyfile validation happen on the remote Docker host during deploy.

In full deploy mode, the script verifies Cloudflare DNS write access before
making server changes by creating and immediately deleting a temporary TXT
record on the target hostname. TXT and A records can coexist, and the script
deletes the temporary record by Cloudflare record id. The actual DNS A-record
upsert happens later, after the remote containers start, the gateway passes
local health on the server, and the origin is reachable on public TCP `80` via
`curl --resolve`. This avoids cutting traffic to a server that cannot run the
app or cannot receive HTTP-01 validation traffic.

If the token is limited to one zone and zone lookup fails, pass `CF_ZONE_ID=...`.
Set `TTL=1` for Cloudflare automatic TTL, or a concrete value such as `300`
when `PROXIED=false`. If `PROXIED=true`, leave `TTL=1` because Cloudflare
proxied records use automatic TTL.
For `PROXIED=false`, HTTPS health checks use `curl --resolve` to verify the
origin immediately without waiting for local DNS caches. For `PROXIED=true`,
HTTPS health checks use normal DNS resolution so the Cloudflare edge path is
verified.
If DNS is already correct and you intentionally do not want the script to change
Cloudflare, set `SKIP_DNS=true`. With `PROXIED=false`, the deploy script then
checks public A-record resolution before building or touching the server and
fails unless the hostname resolves only to `TARGET_IP`. This is not optional:
Caddy and Let's Encrypt use real public DNS, not the deploy script's
`curl --resolve` override.
`ROLLBACK_ON_FAILURE=true` is enabled by default. After the new files have been
installed on the server, failures before DNS cutover restore the latest config
backup and restart the previous compose stack when a backup exists. The script
does not pretend to roll back a first deploy with no backup, and it does not
try to undo Cloudflare changes after DNS cutover.
If Cloudflare already has multiple `A` records for the same hostname, the DNS
script fails instead of updating only one record. Clean up the duplicates first
so traffic cannot randomly hit an old origin.
The DNS script also refuses to continue when the hostname has a same-name
`CNAME` or `AAAA` record. `CNAME` conflicts with creating an `A` record, and
stale `AAAA` records can send IPv6-capable clients to an old origin.

Run the deployed health check again at any time:

```bash
ENV_FILE=deploy/deploy-1g.env.local deploy/check-1g.sh
```

Restore the latest backed-up remote config:

```bash
ENV_FILE=deploy/deploy-1g.env.local deploy/restore-1g-config.sh
```

When `TARGET_REGION=auto`, restore tries Japan first and then Hong Kong, and
selects the first server that already has `${REMOTE_DIR}/docker-compose.1g.yml`.
That avoids requiring a healthy `/health` endpoint during rollback.

Restore a specific config backup without restarting services:

```bash
BACKUP_FILE=backups/config-20260516T060000Z.tar.gz RESTART=false \
  ENV_FILE=deploy/deploy-1g.env.local deploy/restore-1g-config.sh
```

## Verification

For cloud-only deployment, run the non-Docker checks locally:

```bash
deploy/test-1g-cloud.sh
```

`test-1g-cloud.sh` runs only local non-Docker checks: shell syntax, doctor
validation, Cloudflare DNS mocks, frontend probe mocks, remote preflight mocks,
completion audit mocks, and a source archive smoke test that verifies required
build files are included while `.env` files and `node_modules` are excluded.

Run individual non-Docker checks when you need to isolate a failure:

```bash
deploy/test-1g-cloud.sh
deploy/test-doctor-1g.sh
deploy/test-cloudflare-upsert-dns.sh
deploy/test-probe-frontend.sh
deploy/test-remote-1g-preflight.sh
deploy/audit-1g-completion.sh
```

The script:

1. Runs a remote preflight through root SSH or sudo for CPU arch, deploy disk
   space, Docker data disk space, memory, and ports.
2. Verifies Cloudflare DNS write access with a temporary TXT record when
   `SKIP_DNS=false`.
3. Creates a source archive on the local machine and uploads it to the VPS.
4. Installs Docker and a swapfile on the server. `SWAP_SIZE` defaults to `2G`
   and accepts `M` or `G` suffixes, such as `2048M` or `2G`.
5. Backs up existing remote `.env`, compose, and Caddy config if present.
6. Uploads the source archive, generated `.env`, Caddyfile, and 1G compose
   profile into a remote staging directory. If upload or staging validation
   fails, the script attempts to remove that staging directory before exiting.
7. Validates the generated Caddyfile before touching the remote service state.
8. Sets the staged `.env` permissions to `600`.
9. Builds the Docker image on the VPS with 1G build-time memory limits.
10. Validates the staged remote compose config.
11. Installs the staged files into the live deployment directory.
12. Starts PostgreSQL and Redis, then force-recreates Gateway and Caddy so the
    newly built `gateway:cloud` image is actually running.
13. Removes the uploaded source archive and prunes dangling Docker images after
    a successful startup.
14. Verifies `http://127.0.0.1:18080/health`,
    `http://127.0.0.1:18080/login`, and the built `/assets/*.js` frontend
    asset referenced by the login page on the server.
15. Verifies `http://$DOMAIN/health` reaches the origin through public TCP `80`
    using `curl --resolve`.
16. Upserts the Cloudflare `A` record.
17. Verifies
    `https://$DOMAIN/health`, `https://$DOMAIN/login`, and the built frontend
    asset from the local machine.

If a failure happens after live files are installed but before DNS cutover, and
`ROLLBACK_ON_FAILURE=true`, the deploy script attempts to restore the latest
remote config backup and restart the previous compose stack.
If the script generated an admin password and a failure leaves the new live
config in place, it prints the generated `ADMIN_EMAIL` and `ADMIN_PASSWORD`
again so the running first deploy is still accessible.

`deploy/test-doctor-1g.sh` verifies local validation of placeholder values,
invalid booleans, proxied TTL, missing Cloudflare token, invalid email, unsafe
remote `.env` tokens, missing SSH keys, and command-line overrides for
`ENV_FILE`.
`deploy/test-cloudflare-upsert-dns.sh` does not call Cloudflare. It uses a local
mock `curl` to verify DNS creation, update, write-check, same-name `CNAME`,
same-name `AAAA`, duplicate `A` records, and invalid proxied TTL handling.
`deploy/test-probe-frontend.sh` uses a local mock `curl` to verify `/health`,
`/login`, Vue app root detection, frontend JS asset detection, absolute asset
URLs, asset fetch failures, `CHECK_HEALTH=false`, and `CURL_RESOLVE` forwarding.
`deploy/audit-1g-completion.sh` verifies that the final handoff evidence exists,
has restrictive permissions, contains no persisted SSH or Cloudflare secrets,
matches the configured domain and target IP, and includes Cloudflare, remote
Compose, and HTTPS frontend checks.
`deploy/test-remote-1g-preflight.sh` uses local command mocks to verify remote
preflight decisions for CPU architecture, disk gates, 80/443 port conflicts,
the existing `gateway-caddy` exception, and the `/proc/net/tcp` fallback path.
`deploy/test-remote-1g-bootstrap.sh` uses local command mocks to verify Docker
package installation and the `get.docker.com` fallback path without touching the
network or local Docker daemon.

If the remote frontend probe or final HTTPS health check fails, the deploy
script automatically collects remote compose status, one-shot Docker memory
stats, recent Caddy/Gateway/PostgreSQL/Redis logs, disk space, memory usage,
and listening ports before exiting.

## Remote commands

```bash
cd /opt/gateway
docker compose -f docker-compose.1g.yml ps
docker compose -f docker-compose.1g.yml logs -f gateway
docker compose -f docker-compose.1g.yml logs -f caddy
```

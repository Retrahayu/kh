# Security posture — SIMRS Khanza on Rocky 9 + Webswing

Findings from an adversarial review of the live deployment (29 Oct 2026), each with severity,
evidence, mitigation and status. Evidence is reproducible with `deploy/verify-khanza.sh`.

## Findings

| # | Severity | Finding | Evidence | Mitigation | Status |
|---|---|---|---|---|---|
| 1 | **Critical** | Webswing's security module ships **hardcoded credentials** — `pwd` / `admin`, `support`, `user` are string literals in `DemoSecurityModule.class`. There is **no config knob** to change them. | `javap -c -p org/webswing/security/modules/demo/DemoSecurityModule.class` | Do not expose the app port. Put the edge in front: `deploy/conf/khanza-httpd-proxy.conf.example` (TLS + Basic auth + IP allowlist) and bind Webswing to `127.0.0.1`; or swap in a real Webswing security module / license. | **pending** (needs your Tencent SG change) |
| 2 | **High** | App port `:8080` is reachable from the internet and is being probed: `logs/audit.log` has a failed `admin` login from `176.65.148.94` (29-Oct 00:47) among 7 distinct public addresses. | `grep 'LOGIN.*FAILED' logs/audit.log` | Tencent security-group allowlist (your console) or the reverse-proxy edge in #1. | **pending** |
| 3 | **High** | MariaDB listens on `0.0.0.0:3306` and `root@'%'` has a short, guessable password → a port scan yields the DB superuser. | `ss -ltnp`, `SELECT user,host FROM mysql.user` | Least-privilege schema user for the app (done, #4) + restrict `bind-address` to loopback + the private interface (`deploy/harden-khanza.sh --db-bind`) + SG rule. | **partially done** |
| 4 | Medium | Apps connected as DB **superuser** with a shared weak password. | `conf/conf.php`, `database.xml` | `deploy/harden-khanza.sh --db-user` created `khanza@'%'` with a generated 32-char password, grants scoped to `sik.*` only, and re-rendered every config from one env file. `root@'%'` kept as a documented fallback until a soak period, then dropped. | **done** |
| 5 | Medium | Two **anonymous MySQL accounts** (`''@localhost`, `''@<hostname>`) survived `mariadb-secure-installation`. | `SELECT COUNT(*) FROM mysql.user WHERE user=''` | `deploy/harden-khanza.sh --anon` removes them (idempotent). | **done** |
| 6 | Medium | Nothing supervised the GUI: Webswing + Xvfb ran inside an unrelated service's cgroup and were SIGKILLed with it; no unit, no restart. | `journalctl` (`Killing process … (Webswing Proces) with signal SIGKILL`), `logs/stats.log` stops mid-line | `deploy/systemd/{xvfb,webswing}.service` — own cgroup, `Restart=on-failure`, `Requires=xvfb.service`. | **done** |
| 7 | Medium | `conf/conf.php` exposed in the web root contains the DB password **and** the AES key/IV; the same values are duplicated in the client's encrypted `database.xml`. Config drift by hand-editing is the norm. | `grep -n secret_key conf/conf.php` | One source of truth: `deploy/render-config.py` renders `conf.php` ×2 and the encrypted `database.xml` from `/etc/khanza/khanza.env` (mode 600, git-ignored) and is idempotent. | **done** |
| 8 | Low | SELinux disabled, firewalld inactive → no host-layer defence behind the SG. | `getenforce`, `systemctl is-active firewalld` | Enable firewalld with an explicit allowlist, or SELinux enforcing with httpd/mariadb booleans. | **pending** |
| 9 | Low | phpMyAdmin publicly reachable at `/phpmyadmin`. | `curl -o /dev/null -w '%{http_code}'` → 200 | IP allowlist in httpd, or HTTP Basic auth. | **pending** |
| 10 | Low | Webswing **eval** build: cosmetic banner, no licence. | Webswing UI banner | Buy a licence, keep the banner, or run the client per-PC. | **accepted** |

## Standing rules

1. **No secret ever enters git.** `.gitignore` covers `setting/database.xml`, `**/conf/conf.php`,
   `database.ini`, `*.sql`, `*.jar`, `*.p12`, `.env`. Verify with
   `git grep -nE '<live-db-password>|<live-ip>|<live-aes-key>'` (fill in locally, never commit the
   filled-in command) before every push.
2. **Config is generated, not edited.** Change `/etc/khanza/khanza.env`, then
   `deploy/render-config.py --apply`. Hand edits drift and get committed.
3. **Credentials rotate through one command.** Same renderer: new password once, applied to the
   web modules and the AES-encrypted client config together.
4. **Least privilege.** Apps use a schema-scoped MySQL user, never `root`.
5. **The edge is not the app.** TLS, authentication and allowlists live in httpd/SG, not in
   Webswing's demo security module (see finding #1).

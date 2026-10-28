# `deploy/` — automation for the Rocky 9 + Webswing deployment

Declarative where it can be, idempotent where it must be. Nothing here writes outside the paths
named in `lib/common.sh`, and every mutating script supports a dry-run.

| File | Purpose | Mutates state? |
|---|---|---|
| `lib/common.sh` | shared helpers (logging, counters, env loading, assertions) | no |
| `render-config.py` | **single source of truth**: renders `webapps/conf/conf.php`, `epasien/conf/conf.php` and the AES-encrypted client `database.xml` from one env file | only with `--apply` |
| `verify-khanza.sh` | re-asserts every "verified" claim in the runbook against live state | no (read-only) |
| `harden-khanza.sh` | idempotent security mitigations (anonymous accounts, least-privilege DB user, DB bind, units) | only with `--apply` |
| `backup-khanza.sh` | DB dump + config/unit snapshot + SHA-256 manifest, with retention | writes to `/var/backups/khanza` |
| `systemd/` | `xvfb.service` + `webswing.service` (own cgroup, self-healing) | via `systemctl` |
| `conf/` | `khanza.env.example` (config template) and an httpd edge-proxy template | no |

## First run

```bash
sudo install -m 600 deploy/conf/khanza.env.example /etc/khanza/khanza.env
sudo "${EDITOR:-vi}" /etc/khanza/khanza.env            # fill DB + AES values once
sudo deploy/render-config.py --check                   # show drift, change nothing
sudo deploy/render-config.py --apply                   # write configs (timestamped .bak kept)
sudo deploy/harden-khanza.sh                           # dry-run report of what hardening would do
sudo deploy/harden-khanza.sh --apply                   # do it
sudo deploy/verify-khanza.sh                           # prove the deployment still matches the doc
sudo deploy/backup-khanza.sh                           # dump + snapshot
```

## Design rules

- **One source of truth.** Connection settings exist in exactly one place (`khanza.env`); every
  consumer (`conf.php` ×2, `database.xml` ×3 including the Webswing drop-in) is *rendered*.
- **Idempotent.** Running `--apply` twice changes nothing the second time; `verify` after
  `render` is the acceptance test.
- **Dry-run by default.** Mutating scripts print intent unless `--apply` is passed.
- **Secrets stay local.** The env file is `0600`, git-ignored, and never echoed (helpers print
  `<set:N chars>`, not values).
- **Fail loudly, exit non-zero.** Scripts are for CI-ish use and for humans who paste output.

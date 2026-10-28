# SIMRS Khanza — Deployment (Rocky Linux 9 + Webswing)

Deployment package that runs the **SIMRS Khanza** hospital information system on a Rocky Linux 9
server: MariaDB `sik` schema, PHP web modules under `httpd`, and the Java desktop client
**streamed to any browser through Webswing** so client PCs need **no local JDK**.

> **No secrets in this repository.** All credentials, IPs and encryption material are
> placeholders, and `.gitignore` keeps the files that hold live values out of git. Verified with
> `git grep` for the live password, the server IPs and the private keys: **0 hits**.

**Rev 3 (29 Oct 2026)** — facts corrected against the live host, mitigations now automated in
`deploy/`, and the GUI is supervised by systemd. See [Corrections](#corrections-since-rev-1).

---

## Status

| Component | State |
|---|---|
| MariaDB 11.3.2, schema `sik`, latin1_swedish_ci, **1188 tables** | working |
| PHP 8.5.12 (Remi) + `mysqli`/`pdo_mysql`/`mbstring`/`xml`/`curl`/`gd`, phpMyAdmin 5.2.3 | working |
| Web modules `webapps/` + `epasien/` deployed to `/var/www/html`, HTTP 200 | working |
| BellSoft Liberica **JDK 11 Full** (JavaFX jmods) as the active `java` | working |
| Webswing 26.2 eval, drop-in at `/khanza` on `:8080`, `Xvfb :99` + gtk3 for JavaFX | working |
| GUI supervision (`xvfb.service` + `webswing.service`) | **in this repo, `systemctl enable --now` it** |
| App DB account is least-privilege, not `root` | **automated** (`deploy/harden-khanza.sh --db-user`) |
| Edge hardening: TLS + auth + allowlist in front of Webswing, SG rules | **pending — your call** (see `SECURITY.md`) |
| `resumepasien/` Delphi client, `KhanzaHMS*` service modules | not deployed |

Verified by `deploy/verify-khanza.sh`, which re-asserts every claim from live state
(86 PASS / 3 FAIL / 4 WARN when last run — the FAILs were pending actions, not broken claims).

---

## Architecture

```
                    ┌────────────────────────────── Rocky Linux 9.8 ─────────────────────────────┐
  Browser (any PC) ─┤ httpd :80/:443            Webswing 26.2 (Jetty) :8080                     │
   — no local JDK   │  ├ webapps/  epasien/      └─ streams a server-side Java session            │
                    │  │   (PHP + mysqli)             └─ SIMRSKhanza (Swing + JavaFX lib)       │
                    │  └ phpMyAdmin                    ├─ MariaDB 11.3.2 ──▶ sik  (1188 tables)  │
                    │      Xvfb :99 (llvmpipe GLX, needed by JavaFX)                                │
                    └──────────────────────────────────────────────────────────────────────────────┘
```

- **OS:** Rocky Linux 9.8 (RHEL-9 family → `dnf`, `httpd`, `mariadb-server`).
- **DB:** MariaDB 11.3.2, schema `sik`, latin1 / `latin1_swedish_ci`.
- **Web:** `httpd` + PHP 8.5 (Remi) serving `webapps/` and `epasien/`.
- **Java:** BellSoft Liberica JDK 11 Full (bundles JavaFX, required by a client dependency).
- **GUI:** Webswing drop-in at path `/khanza`, app port `:8080`.

---

## Repository layout

```
.
├── README.md                     # this file
├── SECURITY.md                   # threat model, findings, mitigations, status
├── DEPLOYMENT-ROCKY-9.md         # step-by-step runbook (redacted)
├── .gitignore                    # keeps secrets and large binaries out of git
├── webapps/                      # PHP web modules as deployed (sanitized conf.php)
├── epasien/                      # PHP e-medical-record module (sanitized conf.php)
├── binaries/README.md            # release inventory: what is excluded (jar, dumps, second
│                                 # web-module copy) and how to re-fetch it
└── deploy/
    ├── README.md                 # how to run everything below
    ├── lib/common.sh             # shared shell helpers
    ├── render-config.py          # renders every config from ONE env file
    ├── verify-khanza.sh          # re-asserts the runbook's claims (read-only)
    ├── harden-khanza.sh          # idempotent mitigations (dry-run by default)
    ├── backup-khanza.sh          # DB dump + config snapshot + sha256 manifest
    ├── systemd/                  # xvfb.service, webswing.service
    └── conf/                     # khanza.env.example, httpd edge-proxy template
```

---

## Quick start

```bash
git clone https://github.com/Retrahayu/kh && cd kh

# 1. Config: ONE file, git-ignored, mode 600. Nothing else is hand-edited.
sudo install -m 600 deploy/conf/khanza.env.example /etc/khanza/khanza.env
sudo "${EDITOR:-vi}" /etc/khanza/khanza.env

# 2. Render every consumer (webapps/conf.php, epasien/conf.php, AES-encrypted
#    client database.xml + the Webswing drop-in copy) from that file.
sudo deploy/render-config.py --check     # show drift only
sudo deploy/render-config.py --apply     # write, keeping timestamped .bak files

# 3. Mitigations (dry-run first; it prints exactly what it will do)
sudo deploy/harden-khanza.sh
sudo deploy/harden-khanza.sh --apply

# 4. Supervise the GUI (own cgroup → survives reboots and unrelated service restarts)
sudo install -m 644 deploy/systemd/*.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now xvfb.service webswing.service

# 5. Prove it, then back it up
sudo deploy/verify-khanza.sh
sudo deploy/backup-khanza.sh

# 6. Use it
xdg-open http://<server-ip>:8080/khanza/     # or curl -I for a health check
```

Full detail (MariaDB, PHP/Remi upgrade, Java, Webswing packaging, crypto) is in
[`DEPLOYMENT-ROCKY-9.md`](DEPLOYMENT-ROCKY-9.md).

---

## The four things that actually bite

1. **Full dependency `lib/`** — `khanza.jar` is a *thin* jar; its manifest `Class-Path` lists
   280 jars (2026-10 stock build; count it, it changes). A partial set — e.g. the 50-jar `lib/`
   that ships in `binaries/` — dies with `NoClassDefFoundError: usu/widget/util/WidgetUtilities`.
   The working set is 304 jars / 807 MB, including `UsuLibrary.jar`.
2. **JavaFX needs a real X display** — a client dependency lazily runs `new JFXPanel()`; under
   Webswing's built-in XHeadless this throws `GtkApplication … ES2 Prism: Error - GLX extension
   is not supported` and the session dies seconds after launch (looks like a forced logout).
   Fix: `Xvfb :99` (software GLX via Mesa llvmpipe) + `gtk3` + `DISPLAY=:99` inherited by the
   child JVM. `-Dprism.order=sw` is **not** required. `khanza.jar` itself has zero JavaFX
   references — it's a third-party lib.
3. **One `/khanza` definition** — keep the root `webswing.config` entry as the one-line drop-in
   reference (`"/khanza": "${webswing.dropin.dir}/khanza"`); an inline `swingConfig` block (what
   a helper script wrote once) points at the 50-jar `lib/` and reproduces (1).
4. **Supervise it, or it dies silently** — a hand-started Webswing lives in the cgroup of
   whatever launched it; when that service restarts, systemd SIGKILLs Webswing *and* its
   per-session JVMs, and nothing brings it back (observed: `logs/stats.log` stopping mid-line,
   `:8080` silent). Use the units in `deploy/systemd/`.

Two more, worth knowing:

- The **admin console** is served by the app server on `:8080` (`-serveradmin -adminctx /admin`)
  because the launcher attaches `webswing-admin-server.war`; the standalone `admin/admin.sh`
  console binds **8090** (http) / **9443** (https). There is no `8081`.
- The **Webswing eval build** shows a cosmetic "evaluation version" banner that config cannot
  remove (license key in the admin console, or a per-PC desktop client instead).

---

## Configuration (never committed)

| File | Holds | Rendered by |
|---|---|---|
| `/etc/khanza/khanza.env` | every connection setting (DB host/user/pass, AES key/IV) | — (source of truth, mode 600) |
| `webapps/conf/conf.php`, `epasien/conf/conf.php` | DB creds + AES key/IV for PHP | `deploy/render-config.py` |
| `setting/database.xml` (client, `_pkg`, drop-in) | AES-encrypted JDBC connection | `deploy/render-config.py` |
| `*.sql` dumps | schema + data (may contain patient data) | never committed |

`.gitignore` also covers `database.ini` (resumepasien, *plaintext* credentials),
`webswing-admin.properties` (connection secret) and `*.p12`.

---

## Security

See [`SECURITY.md`](SECURITY.md) for the full findings table (severity, evidence, mitigation,
status). Headlines:

- Webswing's demo security module ships **hardcoded credentials** (`admin`/`support`/`user`
  with password `pwd`) in bytecode — **not configurable**. Never expose `:8080` to the internet;
  put TLS + auth + an IP allowlist in front (`deploy/conf/khanza-httpd-proxy.conf.example`) and
  bind Webswing to `127.0.0.1`.
- The app port is internet-reachable and has been probed by a scanner (a failed `admin` login
  from a public address is in `logs/audit.log`). Restrict it in the Tencent security group.
- Apps should use a **schema-scoped DB user**, not `root`; `deploy/harden-khanza.sh --db-user`
  does that and re-renders every config from the env file.
- MariaDB currently listens on `0.0.0.0:3306`; `--db-bind` restricts it to loopback + the
  private interface (only if no external PC connects over the public IP).
- Change the Khanza default login (`spv`/`server`) before real use.

---

## Corrections since rev 1

| Rev 1 said | Reality (verified 29 Oct 2026) |
|---|---|
| admin console at `https://<server>:8081/webswing/admin` | no such port; `/admin` on `:8080` or 8090/9443 standalone |
| "all **181** manifest-referenced jars present" | **280** jars in the manifest (304 on disk), 0 missing |
| "`php-gd` is **not** installed" | installed (`php-gd-8.5.12`, Remi) |
| `binaries/` = "web module (`index.php`, `conf.php`, `.htaccess`, `nbproject/`)" | `binaries/` = released artifacts (`khanza.jar`, `lib/` 50 jars, `setting/`, `sik.sql`, `webapps/`); no `.htaccess`/`nbproject` |
| drop-in "requires `web/` + `web/webroot/`" | `web/` must exist; `webroot` is absent in the working deployment |
| fix = `DISPLAY=:99` **+ `-Dprism.order=sw`** | the flag isn't in the running config and isn't needed |
| "change the Webswing admin password" | impossible with the demo module — it's compiled in; use the edge proxy |
| "Status: login screen renders" | true while supervised; it had been SIGKILLed with its parent cgroup |

---

## Licensing and credits

- **SIMRS Khanza** — © Khanza.Soft Media, distributed under the **Aladdin Free Public License**
  (free use and redistribution; **selling** it or profiting from it without permission is not
  allowed). This package redistributes the application's PHP modules unchanged (sanitized
  configs only) and ships **no** prebuilt binaries.
- **Webswing** — the build in use is the evaluation edition; a licence is required to remove
  the banner.
- This deployment package, its runbook and scripts are provided as-is for operational use.

**Never commit patient data.** Schema dumps, uploads and generated documents stay out of git.

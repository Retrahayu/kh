# SIMRS Khanza — Rocky Linux 9.8 Deployment (Actual Server)

> Focused extract of **Section 8** ("Rocky Linux 9.8 Deployment — Actual Server") from the full
> deployment guide. This is the live-server runbook: Rocky Linux 9.8, `dnf`, MariaDB, httpd/PHP,
> BellSoft JDK 11, and the Webswing browser GUI.
>
> **No secrets in this file** — credential / IP / AES placeholders only. The full guide
> (`DEPLOYMENT.md`, kept private) holds the live values plus the Windows XAMPP and Ubuntu/Debian
> variants and the crypto reference.
>
> **Revision 2 (29 Oct 2026)** — four factual errors in revision 1 are corrected here
> (`:8081` admin port, the "181 manifest jars" count, the stale `php-gd` line, and the
> description of `binaries/`), plus a new **8k** on supervising the GUI, and the
> `client/_pkg/` staging-tree description. See the [corrections table](#appendix-a--corrections-in-revision-2)
> and re-check the deployment with `verify-khanza.sh` (Appendix B) instead of trusting prose.

---

## 8. Rocky Linux 9.8 Deployment (Actual Server)

The live deployment target: **Rocky Linux 9.8 (Blue Onyx)**, installed under
`/opt/simrs-khanza`. RHEL-9 family → use `dnf`, `httpd`, `mariadb-server`. On this host
**SELinux is Disabled** and **firewalld is inactive**, so the SELinux/firewall steps below
are optional hardening, not blockers.

### 8a. Environment (verified)

- **OS:** Rocky Linux 9.8, `ID_LIKE="rhel centos fedora"`, `PLATFORM_ID=platform:el9`.
- **User:** root; working directory `/opt/simrs-khanza` (≈2.2 GB, 38k files).
- **Layout:**
  - `/opt/simrs-khanza/source/` — full SIMRS-Khanza repo (git clone, ~1.1 GB): the Ant/NetBeans
    project (`build.xml`, `nbproject/`, `javac.source=1.8`, 1,676 `.java` files under `src/`),
    the PHP web modules (`webapps/`, `epasien/`, plus `eeksekutif/`, `edokter/`, `emcu/`), the
    JasperReports template library (`report/`), the `Khanza*/` companion Java apps, and the
    schema dumps (`sik.sql`, `sik_bridging_lab.sql`, `sik_bridging_radiologi.sql`).
  - `/opt/simrs-khanza/binaries/` — **prebuilt release** pulled from Google Drive via `gdown`
    (**214 MB**). Top level: `khanza.jar` (127 MB stock client), `lib/` (**only 50 jars**),
    `setting/` (stock `database.xml`), `sik.sql` (12.7 MB, a *different* dump from the repo's),
    and `webapps/` (62 MB, 1,909 files — the PHP web-module copy with its own `conf/` holding
    `conf.php`, `index.php`, `calender.php`, `validator.js`; no `.htaccess` and no `nbproject/`
    exist anywhere under `binaries/`). Its `webapps/conf/conf.php` uses `DB_HOST='localhost'`,
    `DB_USER='root'`, `DB_PASS=''`, `DB_NAME='sik'`.
    **Nothing under `binaries/` is what the live server serves** — the deployed web modules came
    from `source/webapps` (8g), and this 50-jar `lib/` is exactly the classpath trap in Gotcha 1.
    Treat `binaries/` as a pristine reference copy only.
  - `/opt/simrs-khanza/client/` — the Webswing client payload assembled by hand (**934 MB**):
    `khanza.jar`, `lib/`, `setting/`, `_pkg/` (drop-in staging tree). See 8j.

### 8b. Get the code & binaries

```bash
mkdir -p /opt/simrs-khanza
dnf install -y git

# Clone the application source (GitHub) — shallow, no history:
git clone --depth 1 --filter=blob:none https://github.com/mas-elkhanza/SIMRS-Khanza.git /opt/simrs-khanza/source

# Pull the released binaries from Google Drive (gdown):
pip3 install gdown==4.6.0
gdown --fuzzy --continue --folder "https://drive.google.com/drive/folders/1AT_ULkvZ8NM8ueFSvC5Aaw8rVBM5Us6d" -O /opt/simrs-khanza/binaries --remaining-ok
```

### 8c. What's in the source tree

- **Web modules (deploy to `/var/www/html`):** `webapps/`, `epasien/`.
- **Client-side, not web modules:** `report/` (JasperReports `.jasper`/`.jrxml` template
  library for the desktop client's report engine) and `resumepasien/` (Delphi desktop app
  `resume.jar`, configured via `setting/database.ini`) — see 8h.
- **DB schema:** `sik.sql` (~13 MB), plus bridging dumps `sik_bridging_radiologi.sql`,
  `sik_bridging_lab.sql`.
- **Client apps:** `Khanza*/` folders, each with its own `setting/database.xml`
  (antrian/loket/poli/apotek, HMS service modules, etc.).
- **Encrypter:** `KhanzaPengenkripsiTeks` (generate encrypted `database.xml` values);
  `KhanzaSecurity16bit` holds the `AESsecurity.EnkripsiAES` implementation.

### 8d. Install & secure MariaDB 11.3.2 (DONE)

```bash
# Official MariaDB repo (Rocky/RHEL-9)
curl -LsS https://r.mariadb.com/downloads/mariadb_repo_setup | bash -s -- --mariadb-server-version="11.3.2"
dnf install MariaDB-server -y
systemctl enable --now mariadb
mariadb-secure-installation     # set root password, drop test db, reload privileges
```

- Binary lives at `/usr/bin/mariadb`; data/config under `/var/lib/mysql` and `/etc/my.cnf.d/`.
- **Check the anonymous accounts.** On the reference host `mariadb-secure-installation` dropped
  the `test` database but left **two anonymous users** (`''@localhost`, `''@<hostname>`).
  Verify with `SELECT user,host FROM mysql.user WHERE user='';` and remove any you find.

### 8e. Install Apache, PHP & Java

**Apache — DONE:**

```bash
dnf update -y
dnf install -y httpd
systemctl enable --now httpd          # active + enabled; listening on port 80
```

**PHP — DONE (upgraded to Remi 8.5):**

```bash
dnf install -y php php-mysqlnd
systemctl restart httpd               # load the PHP module into httpd

dnf install -y https://rpms.remirepo.net/enterprise/remi-release-9.rpm
dnf config-manager --set-enabled crb
dnf module reset php -y
dnf module enable php:remi-8.5 -y
dnf update php* -y
systemctl restart httpd php-fpm
```

Verified on this host: **PHP 8.5.12** (Remi, NTS), extensions `mysqli`, `pdo_mysql`,
`mbstring`, `xml`, `curl` **and `gd`** loaded; `webapps` + `epasien` return HTTP 200 and the DB
link is intact after the upgrade. `php-gd` was missing at first and is now installed
(`php-gd-8.5.12-1.module_php.8.5.el9.remi`) — reinstall it if you rebuild the host.

> **Compatibility note:** Khanza predates PHP 8; 8.5 works for connect/render here, but watch
> for deprecation warnings (implicit-nullable params, etc.) on deeper pages. If a module breaks,
> fall back to a lower stream (e.g. `php:remi-8.0` / `php:remi-8.2`).

```bash
dnf install -y epel-release      # already present on this host
dnf install -y phpMyAdmin
systemctl restart httpd
```

Accessible at `http://<server-ip>/phpmyadmin` (packaged at `/usr/share/phpMyAdmin`, EPEL
5.2.3).

**Java — DONE (BellSoft Liberica 11 Full; needed for the `KhanzaHMS*/` Java service modules):**

```bash
cat > /etc/yum.repos.d/bellsoft.repo <<'EOF'
[BellSoft]
name=BellSoft Repository
baseurl=https://yum.bell-sw.com
enabled=1
gpgcheck=1
gpgkey=https://download.bell-sw.com/pki/GPG-KEY-bellsoft
priority=1
EOF
dnf install -y bellsoft-java11-full
alternatives --set java /usr/lib/jvm/bellsoft-java11-full.x86_64/bin/java

cat > /etc/profile.d/java.sh <<'EOF'
export JAVA_HOME=/usr/lib/jvm/bellsoft-java11-full.x86_64
export PATH=$JAVA_HOME/bin:$PATH
EOF
```

Verified on this host: **OpenJDK 11.0.33 (BellSoft Full)** is the active `java` alternative
(`java.vendor = BellSoft` — note `java -version` alone does *not* print the vendor on this
build; use `java -XshowSettings:properties -version`), `javac` present, and the bundled
**JavaFX** modules present (`javafx.base/controls/fxml/graphics/media/swing/web`). Required by
the Java HMS service/bridge modules (`KhanzaHMSAnjungan`, `KhanzaHMSAutoVerify`,
`KhanzaHMSServiceMandiri/PCare/MobileJKN`, ...).

> Note: the Windows guide recommends BellSoft JDK 15, but **11 Full works** here and is a solid
> LTS base for Khanza's Java components.

### 8f. Import the database — DONE

> **Root now has a password.** `mariadb -u root` will prompt for it; the web `conf.php`
> `DB_PASS` must match (or create a dedicated DB user — see Section 4).

```bash
mariadb -u root -p -e "CREATE DATABASE IF NOT EXISTS sik;"
mariadb -u root -p sik < /opt/simrs-khanza/source/sik.sql
```

**Executed on this host:** created `sik` (latin1 / `latin1_swedish_ci`), imported `sik.sql`
→ **1188 tables** (import wall-time was not recorded). Optional bridging dumps not imported.

### 8g. Deploy web modules — DONE

```bash
cp -r /opt/simrs-khanza/source/webapps /var/www/html/
cp -r /opt/simrs-khanza/source/epasien /var/www/html/     # + report/, resumepasien/ as needed
chown -R apache:apache /var/www/html/webapps /var/www/html/epasien
```

**Config:** each module's DB config is `conf/conf.php` (not `config.php`). Set
`$db_password = "[REDACTED]"` in both `/var/www/html/webapps/conf/conf.php` and
`/var/www/html/epasien/conf/conf.php` (host `localhost`, user `root`, db `sik`).

**Verified:** `http://<server-ip>/webapps/`, `/epasien/` and `/phpmyadmin/` return **HTTP 200**,
and the deployed trees are byte-identical to `source/webapps` / `source/epasien` apart from the
edited `conf/conf.php` in each (diff that, it is the fastest provenance check). A PHP probe
through the same `mysqli_connect(host,root,pass,'sik')` path returns **1188 tables** with
`pasien` present (19 rows at the time of the check). DB link confirmed.

### 8h. Client setup (PENDING)

- **Java clients (`Khanza*/`):** run `KhanzaPengenkripsiTeks`, encrypt host/`sik`/user/pass,
  paste into each `Khanza*/setting/database.xml` — see Section 5.
- **`resumepasien/` (Delphi desktop app):** configure `setting/database.ini` instead (plain INI,
  not encrypted): set `host=<server-ip>`, `database=sik`, `user=root`, `pass=[REDACTED]`, then
  run `resume.jar` on a client PC with a JRE.
  > If this repo ever ships the deployment tree, add `resumepasien/setting/database.ini` to
  > `.gitignore` first — it is plaintext credentials (the current `.gitignore` does **not**
  > cover it).

### 8i. Deployment status

- **Done:** `/opt/simrs-khanza` created; `source/` cloned; `binaries/` pulled via `gdown`;
  MariaDB 11.3.2 installed, enabled, secured, root password set; `httpd` active + enabled;
  PHP 8.5.12 (Remi) with `mysqli`/`gd`; phpMyAdmin 5.2.3; **BellSoft Liberica JDK 11 Full**
  active as `java`; **`sik` imported (1188 tables)**; **`webapps` + `epasien` deployed** to
  `/var/www/html`, owned by `apache`, `conf.php` `DB_PASS` set → HTTP 200. Server IP
  `[REDACTED-IP]`.
- **Pending:** confirm the web login/data screen loads from the DB; `resumepasien/` Delphi
  client `database.ini` + launch (8h). Optional: bridging dumps.
- **Browser GUI (Webswing):** served real sessions through 28 Oct, then was **SIGKILLed** by an
  unrelated service restart because it ran inside that service's cgroup — see 8k. The fix is
  supervision, not more testing.

### 8j. Serve the Khanza GUI in-browser via Webswing

Goal: run the Java desktop client server-side and stream it to any browser — no JDK on client
PCs. Webswing `26.2` eval is at `/opt/webswing/webswing-eval-26.2`; the app is served at
`/khanza` on HTTP `:8080`, and the admin console is on the **same port** (see Gotcha 3).

**Client assets assembled** in `/opt/simrs-khanza/client/`:

- `khanza.jar` (133 MB, `Main-Class: simrskhanza.SIMRSKhanza`) — a **thin** jar; its manifest
  `Class-Path` needs a sibling `lib/` of dependency jars.
- `lib/` — **304 jars (807 MB)**; all **280** manifest-referenced jars present, 0 missing.
  Count it yourself (`unzip -p khanza.jar META-INF/MANIFEST.MF`, count the `Class-Path`
  entries) — the number drifts between releases. Pulled per-file from Drive
  (`client/lib/links.txt`, 328 links → `client/lib/downloads/`) because the *folder* download
  aborted on one unshared `edokter` CSS file.
- `setting/database.xml` — re-encrypted for this server (see crypto note below).

**`client/_pkg/` — the Webswing drop-in staging tree** (this is what gets zipped and deployed):

| Path in `_pkg/` | Contents | Purpose |
|---|---|---|
| `webswing.config` | path `/khanza`, name `SIMRS Khanza`, `webHomeDir: web`, `webFolder: webroot`, `sessionMode: CONTINUE_FOR_BROWSER`, `classPathEntries: ["khanza.jar","lib/*.jar"]`, `launcherConfig.mainClass: simrskhanza.SIMRSKhanza`, `vmArgs: ""` | the per-app config Webswing reads |
| `app/khanza.jar` | 133 MB client jar — a **hardlink** to `client/khanza.jar` (same inode, link count 2) | the app |
| `app/lib/` | **332 entries / 304 jars** (same set as `client/lib/`) | the dependency set |
| `app/setting/` | `database.xml` (byte-identical to `client/setting/database.xml`) + `logo.jpg`, `modem.xml`, `wallpaper.jpg` | the app's own DB config — Webswing runs with `app/` as cwd |
| `web/`, `web/webroot/` | empty (`.keep` only) | the `webHomeDir` / `webFolder` the config points at |

Zipping the *contents* of `_pkg/` (`cd _pkg && zip -r ../khanza.zip .`) produces the flat ZIP
Webswing expands into `apps/khanza/`. The deployed copy keeps its **own**
`app/setting/database.xml`, so **a zip built from the stock `binaries/` tree instead would
silently point the client at `localhost` with an empty password** — build the zip from `_pkg/`
only. Webswing runs the app with `app/` as its working directory, which is why the DB config
lives in `app/setting/` and not in the Webswing root.

**Smoke test PASSED:** `java -Djava.awt.headless=true -jar khanza.jar` loads every class and runs
to `simrskhanza.frmUtama` (main JFrame), stopping only on `HeadlessException` (no X display in a
bare SSH session — exactly what Webswing supplies).

**MariaDB access for the Java app:** JDBC uses TCP, so `root@'localhost'` (socket-only) was
insufficient. Created `root@'%' IDENTIFIED BY '[REDACTED]'` + grant; MariaDB listens on
`0.0.0.0:3306`. TCP login verified — and this is the single biggest exposure on the host
(Section 13).

**`database.xml` encryption (reproduced headless):** AES/CBC/PKCS5Padding, a 16-byte key and a
16-byte IV (both redacted here; the pair is a hardcoded Khanza default and is in
`AESsecurity.EnkripsiAES` inside `KhanzaSecurity16bit.jar`, source in the repo), Base64 output.
Set `HOST=<server-ip>`, `DATABASE=sik`, `PORT=3306`, `USER=root`, `PAS=[REDACTED]` (plus the
matching `HOST/USER/PAS HYBRIDWEB`). A raw XML diff of the shipped file is a trap: many keys in
`database.xml` are *not* encrypted with this scheme, so a "bad decrypt" on e.g. `CARICEPAT` is
expected and harmless — check the keys you care about.

**Webswing drop-in:** packaged `khanza.zip` into `apps/`; Webswing extracts to `apps/khanza/` and
runs with `app/` as cwd so `app/setting/database.xml` is found. The `web/` folder named by
`webHomeDir` must **exist** (empty is fine — `.keep` keeps it inside the zip); `webFolder:
webroot` is only consulted for static web assets, and the deployed copy has **no** `webroot` at
all while serving sessions fine (verified 28 Oct). JDBC from `mysql-connector-java-5.1.47` to
`<server-ip>/sik` connects, `pasien`=19. Access `http://<server-ip>:8080/khanza`. Note:
`zip -d 'web*'` also matches `webswing.config` — delete it back or use a precise pattern.

**⚠️ Gotcha 1 — two conflicting `/khanza` configs.** The drop-in at
`apps/khanza/webswing.config` is correct (classpath `khanza.jar:lib/*.jar` → the **304-jar**
`app/lib`, incl. `UsuLibrary.jar`). But running `setup_khanza.py` **overwrites the root
`webswing.config`** with an inline `/khanza` block whose classpath points at
`/opt/simrs-khanza/binaries/lib` — only **50 jars, missing `UsuLibrary.jar`** →
`NoClassDefFoundError: usu/widget/util/WidgetUtilities`. **Fix:** keep the root `/khanza` as the
one-line drop-in reference `"/khanza": "${webswing.dropin.dir}/khanza"` (the pre-`setup_khanza.py`
backup `webswing.config.bak` is the known-good form; the bad one is preserved as
`webswing.config.bad-setupkhanza`) and **do not re-run `setup_khanza.py`**. The 304-jar drop-in
is the working app.

**⚠️ Gotcha 2 — JavaFX crash kills the session unless a real X display exists.** The app connects
(`Koneksi Berhasil`) but a `lib/` dependency lazily runs `new JFXPanel()`; Webswing's built-in
**XHeadless** display drives the Swing AWT toolkit but **not** JavaFX's GTK/GLX stack, so the
child JVM throws `UnsupportedOperationException: Internal Error` at
`javafx...GtkApplication.<init>` (`ES2 Prism: Error - GLX extension is not supported`) → "No
active window" → the app exits → the browser shows a **forced logout / "Application disconnected
from Server"**. (Khanza's own `khanza.jar` has **zero** JavaFX references — it is a third-party
lib in `lib/`.) **Fix (verified working):** give the child Java process a real virtual X display
with software GLX:

```bash
dnf install -y xorg-x11-server-Xvfb gtk3        # gtk3 provides libgtk-3.so.0 — the missing dep
Xvfb :99 -screen 0 1280x1024x24 -nolisten tcp & # Mesa llvmpipe supplies GLX (libs already present)
DISPLAY=:99 ./webswing.sh start </dev/null >/tmp/ws.log 2>&1
```

`-Dprism.order=sw` is **not** part of the working recipe here: the live drop-in runs with
`"vmArgs": ""` (the flag survives only in the discarded `webswing.config.bad-setupkhanza`).
Evidence from `logs/webswing.log`: the last `ES2 Prism: Error - GLX extension is not supported`
is at **27-Oct 07:06:41**, `Xvfb :99` started at **07:55:48**, no `Using built-in XHeadless` line
appears after 26-Oct 23:44, and the 28-Oct session ran 15 minutes with no JavaFX trace (it ended
on a browser websocket EOF → inactivity timeout, not a crash). **Make `DISPLAY=:99` persistent
with the systemd units in 8k** — hand-starting Xvfb and Webswing is how the GUI ended up dead.

**⚠️ Gotcha 3 — evaluation watermark.** This is Webswing's **eval** build; it shows an
"evaluation version of webswing" banner in the UI. It is cosmetic (no feature is blocked) and
**cannot be removed by config** — only a purchased Webswing license key entered in the admin
console clears it. The console is served by the main server on the **app port**
(`http://<server-ip>:8080/admin`, because the launcher runs with `-serveradmin -adminctx /admin`);
the standalone `admin/admin.sh` console binds **8090** http / **9443** https
(`admin/jetty.properties`). **There is no port 8081** — revision 1 of this guide said so and was
wrong. The real options for the banner are: buy a license, keep the banner, or run `khanza.jar`
+ `lib/` as a desktop app per PC (which gives up the no-JDK-on-clients goal).

> **🔒 Security note — the login is not yours to configure.** The evaluation build's
> `DemoSecurityModule` hardcodes its users in bytecode (`admin`, `support`, `user`, password
> `pwd`); there is no setting that changes them. The admin console is served on the same public
> app port (`-serveradmin -adminctx /admin`), so a reachable `:8080` is effectively an open door
> with code-execution capability. Authenticate at the edge: security-group allowlist plus an
> httpd TLS + Basic-auth reverse proxy (`deploy/conf/khanza-httpd-proxy.conf.example`), with
> Webswing bound to `127.0.0.1` and `/admin` denied there.

**Status:** login screen renders and the DB connects; the Xvfb/`DISPLAY` fix is what keeps the
session alive. Remaining to confirm interactively: a successful `spv`/`[REDACTED]` login and a
data screen loading from `sik`. The GUI is only as available as its supervision — see 8k.

### 8k. Supervise Webswing + Xvfb with systemd (GUI uptime)

**Why this exists — the observed outage.** Webswing and `Xvfb :99` were both started by hand from
an interactive session, so they inherited that session's cgroup. When that service restarted,
systemd tore the cgroup down and SIGKILLed everything in it:

```
Oct 29 04:34:23 <host> systemd[120424]: hermes-gateway.service: Killing process 2820485 (Webswing Proces) with signal SIGKILL
```

`logs/stats.log` stops at `29-Oct-2026-04:24:49` and nothing restarted the GUI; `Xvfb :99` (pid
2800005, started 27-Oct 07:55:48) survived by luck alone. `webswing.sh`'s own `xvfb-run -a`
fallback does **not** save you: it allocates a different display number on every boot, so any
instruction that hardcodes `:99` silently stops applying.

```ini
# /etc/systemd/system/xvfb.service
[Unit]
Description=Virtual X display :99 (llvmpipe GLX) for JavaFX / Webswing
Before=webswing.service

[Service]
Type=simple
ExecStart=/usr/bin/Xvfb :99 -screen 0 1280x1024x24 -nolisten tcp
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
```

```ini
# /etc/systemd/system/webswing.service
[Unit]
Description=Webswing 26.2 - SIMRS Khanza browser GUI (:8080/khanza)
After=network-online.target mariadb.service xvfb.service
Wants=network-online.target
Requires=xvfb.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/webswing/webswing-eval-26.2
Environment=HOME=/opt/webswing/webswing-eval-26.2
Environment=JAVA_HOME=/usr/lib/jvm/bellsoft-java11-full.x86_64
Environment=DISPLAY=:99
ExecStart=/usr/lib/jvm/bellsoft-java11-full.x86_64/bin/java -Xmx2g -jar /opt/webswing/webswing-eval-26.2/server/webswing-jetty-launcher.jar -serveradmin -aw /opt/webswing/webswing-eval-26.2/admin/webswing-admin-server.war -h 0.0.0.0 -j /opt/webswing/webswing-eval-26.2/jetty.properties -c /opt/webswing/webswing-eval-26.2/webswing.config -pfa /opt/webswing/webswing-eval-26.2/admin/webswing-admin.properties -adminctx /admin
Restart=on-failure
RestartSec=5
KillMode=control-group
TimeoutStopSec=90

[Install]
WantedBy=multi-user.target
```

Notes:
- `ExecStart` is the same command `webswing.sh run` issues, but in the **foreground**, so systemd
  owns the cgroup and reaps the per-session child JVMs.
- Do **not** run `webswing.sh start` alongside the unit — it daemonizes outside the cgroup and
  both instances fight over `webswing.pid`.
- The child app process inherits `DISPLAY=:99` from the unit, which is what JavaFX needs.

```bash
pkill -f 'Xvfb :99' ; /opt/webswing/webswing-eval-26.2/webswing.sh stop 2>/dev/null || true
systemctl daemon-reload
systemctl enable --now xvfb.service webswing.service
systemctl status webswing.service --no-pager
ss -ltnp | grep ':8080'
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/khanza      # expect 200
```

**RAM budget:** the reference host has ~7.6 GB and **no swap**. The server JVM takes `-Xmx2g`
and every concurrent Khanza session gets its own JVM (drop-in default heap `-Xmx1024m`), so
budget ~3 GB per concurrent user and cap `maxClients` in `apps/khanza/webswing.config`
accordingly — four simultaneous sessions on that box would OOM-kill the GUI.

---

## Appendix A — corrections in revision 2

| Rev 1 said | Reality (verified) |
|---|---|
| admin console at `https://<server>:8081/webswing/admin` | no port 8081 exists; console is `/admin` on the app port 8080 (`-serveradmin -adminctx /admin`) or 8090/9443 standalone |
| "all **181** manifest-referenced jars present" | manifest `Class-Path` lists **280** jars (304 on disk), 0 missing — conclusion right, count wrong |
| "`php-gd` is **not** installed" | `php-gd-8.5.12-1.module_php.8.5.el9.remi` installed, `gd` loaded |
| `binaries/` = "web module (`index.php`, `conf.php`, `.htaccess`, `nbproject/`)" | top level is `khanza.jar`, `lib/` (50 jars), `setting/`, `sik.sql`, `webapps/`; those PHP files are in `binaries/webapps/conf/`, and there is no `.htaccess`/`nbproject` at all |
| drop-in "requires the `web/` + `web/webroot/` folders" | `web/` must exist; the deployed copy has no `webroot` and runs fine |
| fix = `DISPLAY=:99` **+ `-Dprism.order=sw`** | the flag is not in the running config and is not needed; Xvfb + llvmpipe alone is sufficient |
| "Status: login screen renders and the DB connects" | true when supervised; the GUI was SIGKILLed with its parent cgroup and had no restarter — fixed by 8k |
| "change the Webswing admin password" (rev 1 §13) | impossible: the demo security module hardcodes `admin`/`support`/`user` + `pwd` in bytecode — only edge authentication works |

## Appendix B — `verify-khanza.sh`

Every "verified" claim above was re-asserted mechanically by
`verify-khanza.sh` (read-only; it starts/stops nothing). Run it on the host:

```bash
/root/verify-khanza.sh            # full report, exit 1 if any claim fails
/root/verify-khanza.sh --quiet    # summary only
EXPECT_PASIEN=25 /root/verify-khanza.sh   # accept legitimate drift
```

It checks: OS/version, MariaDB service+version+paths, the `database.xml` decryption and the
resulting TCP JDBC login, table/charset/`pasien` counts, anonymous accounts, `root@'%'` +
password strength, httpd/PHP/extensions/phpMyAdmin/HTTP 200s, deployed-vs-source provenance,
Java alternative + JavaFX jmods, manifest-jar and `lib/` counts, `_pkg` hardlink and config
equality, Webswing config/drop-in correctness, Xvfb + gtk3 + `:8080`, the systemd units, the
DB bind address, and external login attempts from `logs/audit.log`. Last run on the reference
host: **86 PASS, 3 FAIL, 4 WARN, 8 INFO** — all three FAILs are work not yet done rather than
broken claims: the two units are written but not `enable`d, and consequently nothing is
listening on `:8080`.

# SIMRS Khanza — Rocky Linux 9.8 Deployment (Actual Server)

> Focused extract of **Section 8** ("Rocky Linux 9.8 Deployment — Actual Server") from the
> full deployment guide. This is the live-server runbook: Rocky Linux 9.8, `dnf`, MariaDB,
> httpd/PHP, BellSoft JDK 11, and the Webswing browser GUI.
>
> **No secrets in this file** — credential / IP / AES placeholders only. The full guide
> (`DEPLOYMENT.md`) keeps the Windows XAMPP and Ubuntu/Debian variants and the crypto reference.

---

## 8. Rocky Linux 9.8 Deployment (Actual Server)

The live deployment target: **Rocky Linux 9.8 (Blue Onyx)**, installed under
`/opt/simrs-khanza`. RHEL-9 family → use `dnf`, `httpd`, `mariadb-server`. On this host
**SELinux is Disabled** and **firewalld is inactive**, so the SELinux/firewall steps below
are optional hardening, not blockers.

### 8a. Environment (verified)
- **OS:** Rocky Linux 9.8, `ID_LIKE="rhel centos fedora"`, `PLATFORM_ID=platform:el9`.
- **User:** root; working directory `/opt/simrs-khanza`.
- **Layout:**
  - `/opt/simrs-khanza/source/` — full SIMRS-Khanza repo (git clone, ~1.1 GB).
  - `/opt/simrs-khanza/binaries/` — web module pulled from Google Drive via `gdown`
    (`index.php`, `conf.php`, `.htaccess`, `nbproject/`); its `conf.php` uses
    `DB_HOST='localhost'`, `DB_USER='root'`, `DB_PASS=''`, `DB_NAME='sik'`.

### 8b. Get the code & binaries
```bash
mkdir -p /opt/simrs-khanza
dnf install -y git

# Clone the application source (GitHub)
git clone --depth 1 --filter=blob:none https://github.com/mas-elkhanza/SIMRS-Khanza.git /opt/simrs-khanza/source

# Pull the web binaries from Google Drive (gdown)
pip3 install gdown==4.6.0
gdown --fuzzy --continue --folder "https://drive.google.com/drive/folders/1AT_ULkvZ8NM8ueFSvC5Aaw8rVBM5Us6d" -O /opt/simrs-khanza/binaries --remaining-ok
```

### 8c. What's in the source tree
- **Web modules (deploy to `/var/www/html`):** `webapps/`, `epasien/`.
- **Client-side, not web modules:** `report/` (JasperReports `.jasper`/`.jrxml` template
  library for the desktop client's report engine) and `resumepasien/` (Delphi desktop app
  `resume.jar`, configured via `setting/database.ini`) — see Section 8h.
- **DB schema:** `sik.sql` (~13 MB), plus bridging dumps `sik_bridging_radiologi.sql`,
  `sik_bridging_lab.sql`.
- **Client apps:** `Khanza*/` folders, each with its own `setting/database.xml`
  (antrian/loket/poli/apotek, HMS service modules, etc.).
- **Encrypter:** `KhanzaPengenkripsiTeks` (generate encrypted `database.xml` values).

### 8d. Install & secure MariaDB 11.3.2 (DONE)
```bash
# Add the official MariaDB repo (Rocky/RHEL-9)
curl -LsS https://r.mariadb.com/downloads/mariadb_repo_setup | bash -s -- --mariadb-server-version="11.3.2"

# Install server, enable & start, then secure
dnf install MariaDB-server -y
systemctl enable --now mariadb
mariadb-secure-installation     # set root password, drop test db, reload privileges
```
- Binary lives at `/usr/bin/mariadb`; data/config under `/var/lib/mysql` and `/etc/my.cnf.d/`.

### 8e. Install Apache, PHP & Java
**Apache — DONE:**
```bash
dnf update -y
dnf install -y httpd
systemctl enable --now httpd          # active + enabled; listening on port 80
```
**PHP — DONE (upgraded to Remi 8.5):**
```bash
# Base install (Rocky AppStream PHP 8.0)
dnf install -y php php-mysqlnd
systemctl restart httpd               # load the PHP module into httpd

# Upgrade to PHP 8.5 from Remi (Khanza runs on it, verified)
dnf install -y https://rpms.remirepo.net/enterprise/remi-release-9.rpm
dnf config-manager --set-enabled crb
dnf module reset php -y
dnf module enable php:remi-8.5 -y
dnf update php* -y
systemctl restart httpd php-fpm
```
Verified on this host: **PHP 8.5.12** (Remi, NTS), extensions `mysqli`, `pdo_mysql`,
`mbstring`, `xml`, `curl` loaded; `webapps` + `epasien` still return HTTP 200 and the DB
link is intact after the upgrade. `php-gd` is **not** installed — add it
(`dnf install -y php-gd`) if any module needs image handling.
> **Compatibility note:** Khanza predates PHP 8; 8.5 works for connect/render here, but
> watch for deprecation warnings (implicit-nullable params, etc.) on deeper pages. If a
> module breaks, fall back to a lower stream (e.g. `php:remi-8.0` / `php:remi-8.2`).
```bash
dnf install -y epel-release      # already present on this host
dnf install -y phpMyAdmin
systemctl restart httpd
```
Accessible at `http://<server-ip>/phpmyadmin` (packaged at `/usr/share/phpMyAdmin`).

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

# Persist JAVA_HOME for login shells (Webswing / service scripts rely on it)
cat > /etc/profile.d/java.sh <<'EOF'
export JAVA_HOME=/usr/lib/jvm/bellsoft-java11-full.x86_64
export PATH=$JAVA_HOME/bin:$PATH
EOF
```
Verified on this host: **OpenJDK 11.0.33 (BellSoft Full)** is the active `java` alternative,
`javac` present, and the bundled **JavaFX** modules loaded (`javafx.base/controls/fxml/
graphics/media/swing/web`). Required by the Java HMS service/bridge modules
(`KhanzaHMSAnjungan`, `KhanzaHMSAutoVerify`, `KhanzaHMSServiceMandiri/PCare/MobileJKN`, …).
> Note: the Windows guide recommends BellSoft JDK 15, but **11 Full works** here and is a
> solid LTS base for Khanza's Java components.

### 8f. Import the database — DONE
> **Root now has a password** (set via `ALTER USER 'root'@'localhost' IDENTIFIED BY …`).
> `mariadb -u root` will prompt for it; the web `conf.php` `DB_PASS` must be set to match
> (or create a dedicated DB user — see Section 4).
```bash
mariadb -u root -p -e "CREATE DATABASE IF NOT EXISTS sik;"
mariadb -u root -p sik < /opt/simrs-khanza/source/sik.sql
```
**Executed on this host:** created `sik` (latin1 / `latin1_swedish_ci`), imported
`sik.sql` in ~14 s → **1188 tables**. Optional bridging dumps not yet imported.

### 8g. Deploy web modules — DONE
```bash
cp -r /opt/simrs-khanza/source/webapps /var/www/html/
cp -r /opt/simrs-khanza/source/epasien /var/www/html/     # + report/, resumepasien/ as needed
chown -R apache:apache /var/www/html/webapps /var/www/html/epasien
```
**Config:** each module's DB config is `conf/conf.php` (not `config.php`). Set
`$db_password = "[REDACTED]"` in both `/var/www/html/webapps/conf/conf.php` and
`/var/www/html/epasien/conf/conf.php` (host `localhost`, user `root`, db `sik`).

**Verified:** `http://[REDACTED-IP]/webapps/` and `http://[REDACTED-IP]/epasien/` both return
**HTTP 200** with their real page titles and no DB-connection error. A PHP probe through
the same `mysqli_connect(host,root,pass,'sik')` path succeeded: **1188 tables**, `pasien`
table present (19 rows). DB link confirmed.

### 8h. Client setup (PENDING)
- **Java clients (`Khanza*/`):** run `KhanzaPengenkripsiTeks`, encrypt host/`sik`/user/pass,
  paste into each `Khanza*/setting/database.xml` — see Section 5.
- **`resumepasien/` (Delphi desktop app):** configure `setting/database.ini` instead
  (plain INI, not encrypted): set `host=[REDACTED-IP]` (or server IP), `database=sik`,
  `user=root`, `pass=[REDACTED]`, then run `resume.jar` on a client PC with a JRE.

### 8i. Deployment status
- **Done:** `/opt/simrs-khanza` created; `source/` cloned; `binaries/` pulled via `gdown`;
  MariaDB 11.3.2 installed, enabled, secured, root password set; `httpd` active + enabled;
  PHP 8.5.12 (Remi, upgraded from base 8.0; `mysqli` verified, modules still HTTP 200);
  phpMyAdmin 5.2.3; **BellSoft Liberica JDK 11 Full** (JavaFX bundled) active as `java`;
  **`sik` DB imported
  (1188 tables)**; **`webapps` + `epasien` deployed** to `/var/www/html`, owned by
  `apache`, `conf.php` `DB_PASS` set → both return HTTP 200. Server IP `[REDACTED-IP]`.
- **Pending:** confirm web login/data screen loads from the DB; `resumepasien/` Delphi
  client `database.ini` + launch (8h). Optional: `php-gd`, bridging dumps.
- **Browser GUI client (Webswing) — see 8j.**

### 8j. Serve the Khanza GUI in-browser via Webswing (in progress)
Goal: run the Java desktop client server-side and stream it to any browser — no JDK on
client PCs. Webswing `26.2` eval is at `/opt/webswing/webswing-eval-26.2` (admin /
`[REDACTED]`, HTTP `:8080`).

**Client assets assembled** in `/opt/simrs-khanza/client/`:
- `khanza.jar` (133 MB, Main-Class `simrskhanza.SIMRSKhanza`) — a **thin** jar; its
  manifest `Class-Path` needs a sibling `lib/` of dependency jars.
- `lib/` — **304 jars (807 MB)**; all 181 manifest-referenced jars present. Pulled per-file
  from Drive (`links.txt`, 328 links → `downloads/`) because the folder download aborted on
  one unshared `edokter` CSS file.
- `setting/database.xml` — re-encrypted for this server (see crypto note below).

**Smoke test PASSED:** `java -Djava.awt.headless=true -jar khanza.jar` loads every class and
runs to `simrskhanza.frmUtama` (main JFrame), stopping only on `HeadlessException` (no X
display here — exactly what Webswing supplies).

**MariaDB access for the Java app:** JDBC uses TCP, so `root@'localhost'` (socket-only) was
insufficient. Created `root@'%' IDENTIFIED BY '[REDACTED]'` + grant; MariaDB already listens on
`0.0.0.0:3306`. TCP login verified.

**`database.xml` encryption (reproduced headless):** AES/CBC/PKCS5Padding, key
`[REDACTED]`, IV `[REDACTED]`, Base64 — from `AESsecurity.EnkripsiAES`
(`KhanzaSecurity16bit.jar`, source in repo). Set `HOST=[REDACTED-IP]`, `DATABASE=sik`,
`PORT=3306`, `USER=root`, `PAS=[REDACTED]` (+ matching `HOST/USER/PAS HYBRIDWEB`). Original
values were `HOST=localhost`, `PAS=''`, `USERHYBRIDWEB=[REDACTED]`, `PASHYBRIDWEB=[REDACTED]`.

**Webswing drop-in:** packaged `khanza.zip` into `apps/`; Webswing extracts to `apps/khanza/`
and runs with `app/` as cwd so `app/setting/database.xml` is found. Requires the `web/` +
`web/webroot/` folders the config's `webHomeDir`/`webFolder` point to (empty for Khanza).
JDBC from `mysql-connector 5.1.47` to `[REDACTED-IP]/sik` (root/[REDACTED]) connects, `pasien`=19.
Access `http://[REDACTED-IP]:8080/khanza`. Note: `zip -d 'web*'` also matches `webswing.config`
— delete it back or use a precise pattern.

**⚠️ Gotcha 1 — two conflicting `/khanza` configs.** The drop-in at `apps/khanza/webswing.config`
is correct (classpath `khanza.jar:lib/*.jar` → the **304-jar** `app/lib`, incl. `UsuLibrary.jar`).
But running `setup_khanza.py` **overwrites the root `webswing.config`** with an inline `/khanza`
block whose classpath points at `/opt/simrs-khanza/binaries/lib` — only **50 jars, missing
`UsuLibrary.jar`** → `NoClassDefFoundError: usu/widget/util/WidgetUtilities`. **Fix:** keep the
root `/khanza` as the one-line drop-in reference `"/khanza": "${webswing.dropin.dir}/khanza"`
(the pre-`setup_khanza.py` backup `webswing.config.bak` is the known-good form) and **do not
re-run `setup_khanza.py`**. The 304-jar drop-in is the working app.

**⚠️ Gotcha 2 — JavaFX crash kills the session (~11 s after launch).** The app connects
(`Koneksi Berhasil`) but then a dependency library lazily initializes **JavaFX**
(`JFXPanel`), which throws `UnsupportedOperationException: Internal Error` at
`javafx...GtkApplication.<init>` (`ES2 Prism: Error - GLX extension is not supported`).
Webswing's built-in **XHeadless** display is usable by the Swing AWT toolkit but **not** by
JavaFX's GTK/GLX stack, so JavaFX fails → "No active window" → the app exits → the browser
shows a **forced logout / "Application disconnected from Server"**. (Khanza's own `khanza.jar`
has **zero** JavaFX references — it's a third-party lib in `lib/`.)
**Fix (verified working):** give the child Java process a real virtual X display with software GLX:
```bash
dnf install -y xorg-x11-server-Xvfb gtk3        # gtk3 provides libgtk-3.so.0 — the missing dep
Xvfb :99 -screen 0 1280x1024x24 -nolisten tcp & # Mesa llvmpipe supplies GLX (libs already present)
# then start Webswing with DISPLAY inherited by the child app process:
DISPLAY=:99 ./webswing.sh start </dev/null >/tmp/ws.log 2>&1
```
With `DISPLAY=:99` + `-Dprism.order=sw`, a standalone `new JFXPanel()` test initializes cleanly,
and the Khanza session stays alive. Swing still renders via Webswing's toolkit; JavaFX just needs
to not crash. **Make `DISPLAY=:99` persistent** (e.g. export it in the webswing launch wrapper or
a systemd unit) so restarts keep working.

**⚠️ Gotcha 3 — evaluation watermark.** This is Webswing's **eval** build; it shows an
"evaluation version of webswing" banner in the UI. It is cosmetic (no feature is blocked) and
**cannot be removed by config** — only a purchased license key entered in the admin console
(`https://<server>:8081/webswing/admin`) clears it. For a watermark-free client, run the
`khanza.jar` + `lib/` as a normal desktop Java app on a PC instead.

**Status:** login screen renders and the DB connects; the JavaFX/Xvfb fix above is what keeps
the session alive. Remaining to confirm interactively: successful `spv`/`[REDACTED]` login and a
data screen loading from `sik`.

---

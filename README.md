# SIMRS Khanza — Deployment (Rocky Linux + Webswing)

Source, binaries, and the implementation guide for deploying **SIMRS Khanza**
(Khanza Hospital Information System) as a **browser-served Java GUI** on a
**Rocky Linux 9** server, using **Webswing** so client PCs need **no local JDK**.

> This repository intentionally contains **no secrets**. All credentials, IPs, and
> encryption material are kept out of git (see `.gitignore`). Configuration values
> below use placeholders — fill them in locally, never in the repo.

---

## What this repo is

A deployment package for SIMRS Khanza that bundles:

- **`source/`** — the SIMRS-Khanza application tree (PHP web modules + DB schema +
  desktop-client assets).
- **`binaries/`** — the pre-built PHP web modules used by the live deployment.
- **`client/`** — the Java desktop client assembled for browser streaming via Webswing
  (`khanza.jar` + dependency `lib/` + `setting/database.xml`).
- **`DEPLOYMENT.md`** — the full, step-by-step Rocky Linux 9.8 runbook (the authoritative guide).

The end result: the Khanza desktop client runs **server-side** and is streamed to any
browser at `http://<server-ip>:8080/khanza/` — no Java runtime installed on client machines.

---

## Architecture

```
                       ┌─────────────────────────────────────────────┐
  Browser (any PC) ───▶│  Webswing  (Jetty, :8080)                    │
                       │   └─ streams a server-side Java session      │
                       │        └─ SIMRSKhanza (Swing + JavaFX libs)  │
                       │              ├─ MariaDB  ───▶  sik schema    │
                       │              └─ httpd+PHP ──▶ webapps/epasien│
                       └─────────────────────────────────────────────┘
```

- **OS:** Rocky Linux 9 (RHEL-9 family → `dnf`, `httpd`, `mariadb-server`).
- **Database:** MariaDB (11.3.x), schema `sik`.
- **Web:** `httpd` + PHP (8.x from Remi) hosting the `webapps` / `epasien` modules.
- **Java:** BellSoft Liberica JDK 11 Full (bundles JavaFX, required by the `KhanzaHMS*` modules).
- **GUI delivery:** Webswing drop-in at path `/khanza`.

---

## Prerequisites

- Rocky Linux 9 server, root/`sudo` access.
- ~2 GB RAM minimum for the Webswing Java session (more for concurrent users).
- Outbound access to the Fedora/RHEL, MariaDB, Remi, and BellSoft repos.

---

## Quick start (overview)

Full detail is in **`DEPLOYMENT.md`**. Summary:

1. **Get the code & binaries** — clone the app source and pull the web modules.
2. **MariaDB** — install from the official repo, set a root password, create `sik`, import the schema.
3. **Web stack** — install `httpd` + PHP, deploy the `webapps`/`epasien` modules, wire their DB config.
4. **Java** — install BellSoft Liberica JDK 11 Full (with JavaFX).
5. **Webswing** — deploy the Khanza drop-in and serve the GUI at `/khanza`.
6. **Verify** — open `http://<server-ip>:8080/khanza/` and log in.

---

## Serving the GUI via Webswing (key gotchas)

The browser-GUI path has three non-obvious requirements — details and fixes in `DEPLOYMENT.md`:

1. **Use the full dependency `lib/`.** The client jar is "thin"; its manifest needs the
   complete dependency set (incl. `Usu Library.jar`). A partial `lib/` fails with
   `NoClassDefFoundError: usu/widget/util/WidgetUtilities`.
2. **JavaFX needs a real X display.** A third-party library lazily initializes JavaFX,
   which crashes under Webswing's built-in XHeadless (`GtkApplication` / GLX error),
   killing the session ~11 s in. Fix: run an `Xvfb` virtual display with software GLX
   (`dnf install -y xorg-x11-server-Xvfb gtk3`) and launch Webswing with `DISPLAY` set so
   the child process inherits it.
3. **One `/khanza` definition.** Keep the root config's `/khanza` as a single drop-in
   reference; don't let a helper script overwrite it with an inline classpath pointing at
   an incomplete `lib/`.

> The Webswing build in use is an **evaluation** build and shows a cosmetic
> "evaluation version" banner. It is fully functional; clearing the banner requires a
> purchased Webswing license entered in the admin console.

---

## Configuration (local only — never commit)

Each component reads its connection settings from files that are **git-ignored** because
they hold live credentials:

| File | Contains |
|---|---|
| `setting/database.xml` | Client DB connection (AES-encrypted values) |
| `*/conf/conf.php` | Web-module DB connection (host / user / password / db) |
| `*.sql` | Database dumps (schema + data) |

Set these on the server after cloning. See `DEPLOYMENT.md` for the exact fields.

---

## Repository layout

```
.
├── README.md            # this file
├── DEPLOYMENT.md        # full Rocky Linux 9.8 runbook
├── .gitignore           # keeps secrets & binaries out of git
├── source/              # SIMRS-Khanza application tree
├── binaries/            # pre-built PHP web modules
└── client/              # Java client for Webswing (khanza.jar, lib/, setting/)
```

---

## Security notes

- **Never commit** `setting/database.xml`, `*/conf/conf.php`, `*.sql`, or `lib/*.jar`
  (see `.gitignore`).
- Use a **least-privilege** database user for the app — not the DB superuser.
- The Khanza desktop client authenticates against the `sik` database; change the
  default login credentials before any real use.
- Lock down the Webswing admin console and the DB port; don't expose them broadly.

---

## License

The SIMRS Khanza application is open-source software distributed under its own license
(see the upstream project). This deployment package and its guides are provided as-is for
operational use.

## Credits

SIMRS Khanza — Khanza.Soft Media (upstream project).
Deployment package assembled for a Rocky Linux 9 + Webswing deployment.

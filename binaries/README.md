# `binaries/` — released Khanza artifacts (reference copy)

This folder mirrors the **prebuilt release** that is pulled from the upstream Google Drive
folder with `gdown` (see `DEPLOYMENT-ROCKY-9.md` §8b). It is kept here as the *pristine*
reference for the web modules so a rebuild does not depend on Drive being reachable.

## What is in here

| Path | What | In git? |
|---|---|---|
| `webapps/` | PHP web-module tree as shipped in the release | **yes** — sanitized (`conf/conf.php` placeholders only) |

## What is deliberately NOT in git, and why

| Excluded | Size | Why |
|---|---|---|
| `khanza.jar` | 127 MB | exceeds GitHub's 100 MB per-file hard limit **and** `.gitignore` excludes assembled jars. Get it from the upstream Drive folder, or publish it as a **Release asset** / Git LFS object. |
| `lib/` | 14 MB, 50 jars | `.gitignore` excludes `**/lib/*.jar`. This copy is also **incomplete** — it is the 50-jar set that breaks the client (see Gotcha 1). The working 304-jar set lives beside the client, not here. |
| `setting/database.xml` | 13 KB | holds (AES-encrypted) live connection values → credential material. |
| `sik.sql` | 12.7 MB | database dump; may contain real patient data → never in git. |

## Rebuild instead of trusting this copy

```bash
gdown --fuzzy --continue --folder "<upstream-drive-folder-id>" -O /opt/simrs-khanza/binaries --remaining-ok
```

Then re-apply your local config with the renderer, **never by hand**:

```bash
sudo install -m 600 deploy/conf/khanza.env.example /etc/khanza/khanza.env   # edit once
sudo deploy/render-config.py --apply                                        # renders every config from it
```

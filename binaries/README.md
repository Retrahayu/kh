# `binaries/` — released Khanza artifacts (reference description only)

This folder documents the **prebuilt release** pulled from the upstream Google Drive folder with
`gdown` (see `DEPLOYMENT-ROCKY-9.md` §8b). The artifacts themselves are **not committed**:

| Artifact | Size | Why it is not in git |
|---|---|---|
| `khanza.jar` | 127 MB | exceeds GitHub's 100 MB per-file limit; `.gitignore` also excludes assembled jars. Use the upstream Drive folder, or publish it as a **Release asset** / Git LFS object. |
| `lib/` | 14 MB, 50 jars | `.gitignore` excludes `**/lib/*.jar`; this copy is also **incomplete** — it is the 50-jar set that reproduces `NoClassDefFoundError: usu/widget/util/WidgetUtilities` (Gotcha 1). The working set is 304 jars next to the client. |
| `setting/database.xml` | 13 KB | holds the (AES-encrypted) live connection values — credential material. Rendered locally by `deploy/render-config.py`. |
| `sik.sql` | 12.7 MB | database dump; may contain real patient data. Never in git. |
| `webapps/` | 62 MB, 1909 files | **not a duplicate of `../webapps/`.** It is the *released* web-module tree; the deployed tree came from the repository's `source/webapps` (2872 files) and the two differ in 121 entries (e.g. `antrian*.php` exist only in the deployed tree). Kept out of git to keep the repo small — fetch it with the command below. |

## Reproduce the release locally

```bash
gdown --fuzzy --continue --folder "<upstream-drive-folder-id>" \
      -O /opt/simrs-khanza/binaries --remaining-ok

# what the live server actually serves (differs — see the table):
diff -rq /opt/simrs-khanza/binaries/webapps /var/www/html/webapps | head
```

Then build every config from the single env file — never by hand:

```bash
sudo install -m 600 deploy/conf/khanza.env.example /etc/khanza/khanza.env   # edit once
sudo deploy/render-config.py --check && sudo deploy/render-config.py --apply
```

## Sanitization note

The committed `webapps/` and `epasien/` trees in this repository have **placeholder** values in
every `conf/conf.php` (`DB_*_PLACEHOLDER`, `AES_*_PLACEHOLDER`) and in the hybrid-web defines.
The real values are supplied at deploy time by `khanza.env`; nothing here needs to be edited by
hand, and no live credential has ever been committed.

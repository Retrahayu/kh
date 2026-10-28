#!/usr/bin/env python3
"""render-config.py — single source of truth for Khanza connection settings.

Reads one env file and renders every consumer from it, so hand-editing configs (and
committing drift) stops being the workflow:

  * <webroot>/webapps/conf/conf.php     — DB creds, hybrid-web defines, AES key/IV
  * <webroot>/epasien/conf/conf.php     — same, module-specific keys
  * <client>/setting/database.xml       — AES-encrypted Java-client connection
  * <client>/_pkg/app/setting/database.xml + <ws>/apps/khanza/app/setting/database.xml

Idempotent: the same env file produces byte-identical output (AES-CBC with the configured
IV is deterministic), so `--check` right after `--apply` reports no drift.

Usage:
  render-config.py --check              # report drift, exit 1 if any, change nothing
  render-config.py --apply              # write files (timestamped .bak kept)
  render-config.py --env /path         # override env file (default /etc/khanza/khanza.env)
"""
from __future__ import annotations

import argparse
import base64
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

# ── env keys ────────────────────────────────────────────────────────────────
REQUIRED = ("KHANZA_DB_HOST", "KHANZA_DB_NAME", "KHANZA_DB_USER", "KHANZA_DB_PASS",
            "KHANZA_AES_KEY", "KHANZA_AES_IV")

# conf.php line -> env var, matched by the PHP variable name
PHP_MAP = {
    "db_hostname": ("KHANZA_DB_HOST", "double"),
    "db_username": ("KHANZA_DB_USER", "double"),
    "db_password": ("KHANZA_DB_PASS", "double"),
    "db_name":     ("KHANZA_DB_NAME", "double"),
}
PHP_DEFINES = {
    "USERHYBRIDWEB": "KHANZA_HYBRID_USER",
    "PASHYBRIDWEB":  "KHANZA_HYBRID_PASS",
}
PHP_SECRETS = {"secret_key": "KHANZA_AES_KEY", "secret_iv": "KHANZA_AES_IV"}

# database.xml entry -> env var (encrypted values)
XML_MAP = {
    "HOST":          "KHANZA_JDBC_HOST",
    "DATABASE":      "KHANZA_JDBC_NAME",
    "PORT":          "KHANZA_JDBC_PORT",
    "USER":          "KHANZA_JDBC_USER",
    "PAS":           "KHANZA_JDBC_PASS",
    "HOSTHYBRIDWEB": "KHANZA_HYBRID_HOST",
    "USERHYBRIDWEB": "KHANZA_HYBRID_USER",
    "PASHYBRIDWEB":  "KHANZA_HYBRID_PASS",
}


def load_env(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        env[key.strip()] = value.strip().strip('"').strip("'")
    missing = [k for k in REQUIRED if not env.get(k)]
    if missing:
        sys.exit(f"error: {path} is missing: {', '.join(missing)}")
    for k in ("KHANZA_AES_KEY", "KHANZA_AES_IV"):
        if len(env[k].encode()) != 16:
            sys.exit(f"error: {k} must be exactly 16 bytes (got {len(env[k].encode())})")
    return env


def aes_b64(plaintext: str, key: str, iv: str) -> str:
    """Java Cipher(AES/CBC/PKCS5Padding) + Base64, via the openssl CLI."""
    proc = subprocess.run(
        ["openssl", "enc", "-aes-128-cbc", "-K", key.encode().hex(),
         "-iv", iv.encode().hex(), "-base64", "-A"],
        input=plaintext.encode(), capture_output=True, check=True,
    )
    return proc.stdout.decode().strip()


def render_php(text: str, env: dict[str, str], module: str) -> str:
    """Replace credential literals by variable/constant name, preserving everything else."""
    out = []
    for line in text.splitlines(keepends=True):
        m = re.match(r"(\s*\$)(\w+)(\s*=\s*)(\"[^\"]*\"|'[^']*')", line)
        if m and m.group(2) in PHP_MAP:
            var, _, value = m.group(2), m.group(3), env[PHP_MAP[m.group(2)][0]]
            quote = m.group(4)[0]
            line = f"{m.group(1)}{var}{m.group(3)}{quote}{value}{quote}{line[m.end():]}"
        elif m and m.group(2) in PHP_SECRETS:
            var, value = m.group(2), env[PHP_SECRETS[m.group(2)]]
            quote = m.group(4)[0]
            line = f"{m.group(1)}{var}{m.group(3)}{quote}{value}{quote}{line[m.end():]}"
        elif (d := re.match(r"(\s*define\(\s*')(\w+)('\s*,\s*)('[^']*')(.*)", line)) and d.group(2) in PHP_DEFINES:
            env_key = PHP_DEFINES[d.group(2)]
            if env.get(env_key):
                line = f"{d.group(1)}{d.group(2)}{d.group(3)}'{env[env_key]}'{d.group(5)}"
        out.append(line)
    return "".join(out)


def render_xml(text: str, env: dict[str, str]) -> str:
    def sub(match: re.Match[str]) -> str:
        key = match.group(1)
        env_key = XML_MAP.get(key)
        if not env_key or not env.get(env_key):
            return match.group(0)
        return (f'<entry key="{key}">{aes_b64(env[env_key], env["KHANZA_AES_KEY"], env["KHANZA_AES_IV"])}</entry>')

    return re.sub(r'<entry key="([A-Z]+)">[^<]*</entry>', sub, text)


def build_targets(env: dict[str, str]) -> list[tuple[Path, str]]:
    webroot = Path(env.get("KHANZA_WEBROOT", "/var/www/html"))
    client = Path(env.get("KHANZA_CLIENT", "/opt/simrs-khanza/client"))
    ws = Path(env.get("KHANZA_WS", "/opt/webswing/webswing-eval-26.2"))
    targets: list[tuple[Path, str]] = []

    for module in ("webapps", "epasien"):
        php = webroot / module / "conf" / "conf.php"
        if php.is_file():
            targets.append((php, render_php(php.read_text(encoding="utf-8", errors="surrogateescape"),
                                            env, module)))
    for xml in (client / "setting" / "database.xml",
                client / "_pkg" / "app" / "setting" / "database.xml",
                ws / "apps" / "khanza" / "app" / "setting" / "database.xml"):
        if xml.is_file():
            targets.append((xml, render_xml(xml.read_text(encoding="utf-8", errors="surrogateescape"), env)))
    return targets


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--env", default="/etc/khanza/khanza.env", type=Path)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--check", action="store_true", help="report drift only")
    g.add_argument("--apply", action="store_true", help="write files, keeping timestamped backups")
    ap.add_argument("--backup-dir", default="/var/backups/khanza/config-backups",
                    help="where pre-apply copies go (never inside the webroot)")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    env = load_env(args.env)
    targets = build_targets(env)
    if not targets:
        sys.exit("error: no config files found — check KHANZA_WEBROOT / KHANZA_CLIENT / KHANZA_WS")

    drifted = 0
    for path, desired in targets:
        current = path.read_text(encoding="utf-8", errors="surrogateescape")
        if current == desired:
            if not args.quiet:
                print(f"  ok      {path}")
            continue
        drifted += 1
        changed = [i for i, (a, b) in enumerate(zip(current.splitlines(), desired.splitlines()), 1) if a != b]
        print(f"  DRIFT   {path}  ({len(changed)} line(s): {changed[:6]}{'...' if len(changed) > 6 else ''})")
        if args.apply:
            # Backups must NOT live beside the file: a .bak in /var/www/html is served
            # by httpd as plain text and would leak the previous credentials.
            safe = str(path).strip("/").replace("/", "__")
            backup_dir = Path(args.backup_dir)
            backup_dir.mkdir(parents=True, exist_ok=True)
            os.chmod(backup_dir, 0o700)
            backup = backup_dir / f"{safe}.{int(time.time())}.bak"
            shutil.copy2(path, backup)
            os.chmod(backup, 0o600)
            tmp = path.with_name(path.name + ".render.tmp")
            tmp.write_text(desired, encoding="utf-8", errors="surrogateescape")
            os.chmod(tmp, path.stat().st_mode & 0o777)
            tmp.replace(path)
            print(f"          written (backup: {backup})")

    if args.check:
        print(f"\n{drifted} file(s) would change." if drifted else "\nno drift: every config matches the env file.")
        return 1 if drifted else 0
    print(f"\n{drifted} file(s) updated." if drifted else "\nnothing to do: configs already match.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

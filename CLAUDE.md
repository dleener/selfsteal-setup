# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single Bash script (`setup-selfsteal.sh`) plus a user guide (`README.md`). The script configures "SelfSteal" for Xray Reality in the 3x-ui panel: instead of borrowing a foreign site's certificate, Reality's `target` points at a local nginx (`127.0.0.1:<port>`, default `8001`) serving a stub page with a real Let's Encrypt cert for the user's own domain. Target platform is a Debian/Ubuntu VPS run as root; users typically launch it via `bash <(curl ... raw.githubusercontent.com/dleener/selfsteal-setup/main/setup-selfsteal.sh)`, so whatever is on `main` is what users execute.

All user-facing text (script output, usage, README) is in Russian. Keep it that way.

## Checking changes

There is no build, test suite, or lint config. The script cannot be run on macOS (needs root, `apt-get`, `ss`, `ip`, `getent`, systemd). Locally, the available checks are:

```bash
bash -n setup-selfsteal.sh          # syntax check
shellcheck setup-selfsteal.sh       # if installed (not configured in repo)
bash setup-selfsteal.sh --help      # argument parsing / usage text (exits before root check)
```

Real verification requires a disposable Debian/Ubuntu VPS with a domain whose A record points at it.

## Script structure and invariants

The script is linear, top to bottom, under `set -euo pipefail`, with `step`/`ok`/`warn`/`die` output helpers. Stages: args → validation → DNS check → legacy-config migration → port checks → apt install → stub page → `certbot certonly --nginx` → nginx TLS vhost → renewal deploy hook → self-checks → printed 3x-ui instructions.

Things that are easy to break:

- **Re-runs must stay safe** (README promises this). Per-domain files are overwritten; certbot uses `--keep-until-expiring`; the old `/var/www/html/index.html` is backed up only if it differs. `REPLACING=1` (existing `selfsteal-<domain>.conf`, or a legacy hand-made `/etc/nginx/conf.d/selfsteal.conf` for the same `server_name`, which gets moved to `.bak-<date>`) is what lets the "port already in use" check pass on a re-run.
- **Multiple domains per server** are supported via separate ports: each domain gets its own `/etc/nginx/conf.d/selfsteal-<domain>.conf`. The stub page in `/var/www/selfsteal` and the renewal hook are shared.
- **nginx config rollback:** after writing the vhost, `nginx -t` failing deletes the new conf and dies, so a bad config never gets reloaded.
- **Heredoc quoting:** the stub page and nginx vhost use unquoted `<<EOF` (shell variables are interpolated, so nginx variables must be escaped as `\$uri`); the renewal hook uses `<<'EOF'`.
- **3x-ui is never modified** by the script, by design — it only prints the two fields (Target, SNI) the user changes by hand. Don't add panel automation without being asked.

## Keeping README in sync

`README.md` duplicates script behavior in several tables: the parameter list (must match the `case` in arg parsing and `usage()`), the "files created" table, the 3x-ui instructions, and the troubleshooting section (which quotes the script's error messages). When changing flags, paths, defaults, or error text, update both. Example domain throughout is `nl2.proxhub.ru`.

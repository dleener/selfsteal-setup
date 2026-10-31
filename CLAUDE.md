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

The script runs under `set -euo pipefail`, with `step`/`ok`/`warn`/`die` output helpers. Two modes (`MODE`):

- `selfsteal` — the original behavior. Chosen by passing any flags (`-d -e ...`, no questions asked) or by menu item 2.
- `full` ("под ключ") — menu item 1, only reachable interactively. Additionally installs 3x-ui and creates the Reality inbound.

Running with no arguments sets `INTERACTIVE=1`: `interactive_setup` shows the menu and asks questions, reading from `/dev/tty` (so `bash <(curl ...)` and `curl | bash` both work). In this mode DNS failures and bad input re-prompt instead of dying, and the local port is not asked — it's reused from an existing vhost or the next free one from 8001.

After input, the main body is linear and shared by both modes: legacy-config migration → port checks → apt install → stub page → `certbot certonly --nginx` → nginx TLS vhost → renewal deploy hook → self-checks. Then `selfsteal` prints the manual 3x-ui instructions; `full` runs `install_xui` → `setup_inbound` → `finish_full`.

`full` mode details:

- 3x-ui is installed with its official `install.sh` (always latest, from `master`) in non-interactive mode via `XUI_NONINTERACTIVE=1 XUI_USERNAME/XUI_PASSWORD/XUI_PANEL_PORT/XUI_WEB_BASE_PATH XUI_SSL_MODE=none`. Then `x-ui setting ...` and `x-ui cert -webCert -webCertKey` (the same LE cert) are applied every run.
- The panel API is called with a Bearer token from `x-ui setting -getApiToken -tokenName selfsteal-setup` (Bearer requests skip the panel's CSRF check), over HTTPS via `curl --resolve <domain>:<panel port>:127.0.0.1`. Endpoints used: `inbounds/list`, `inbounds/add`, `server/getNewX25519Cert`, `server/restartXrayService`. `settings`/`streamSettings`/`sniffing` are sent as JSON strings (legacy format, accepted by old and new panels); the Reality destination field is `target`.
- Any unexpected API response goes to `manual_inbound`, which prints panel credentials plus the values to enter by hand, rather than a bare `die`.
- State for re-runs is in `/etc/x-ui/selfsteal-setup.env` (sourced). It's written before running the installer. If `/usr/local/x-ui` exists but this file doesn't, the panel isn't ours and `full` mode refuses, offering `selfsteal` mode instead.

Things that are easy to break:

- **Re-runs must stay safe** (README promises this). Per-domain files are overwritten; certbot uses `--keep-until-expiring`; the old `/var/www/html/index.html` is backed up only if it differs. `REPLACING=1` (existing `selfsteal-<domain>.conf`, or a legacy hand-made `/etc/nginx/conf.d/selfsteal.conf` for the same `server_name`, which gets moved to `.bak-<date>`) is what lets the "port already in use" check pass on a re-run.
- **Multiple domains per server** are supported via separate ports: each domain gets its own `/etc/nginx/conf.d/selfsteal-<domain>.conf`. The stub page in `/var/www/selfsteal` and the renewal hook are shared.
- **nginx config rollback:** after writing the vhost, `nginx -t` failing deletes the new conf and dies, so a bad config never gets reloaded.
- **Heredoc quoting:** the stub page and nginx vhost use unquoted `<<EOF` (shell variables are interpolated, so nginx variables must be escaped as `\$uri`); the renewal hooks use `<<'EOF'`.
- **`selfsteal` mode never modifies 3x-ui** — it only prints the two fields (Target, SNI) the user changes by hand. Only `full` mode touches the panel, and only a panel it installed itself.
- **`full` re-runs are idempotent:** saved credentials are reused, the installer is skipped if `/usr/local/x-ui/x-ui` exists, and an inbound already on the Reality port is reused (its UUID/keys are read back to rebuild the link) instead of creating a second one.
- **Renewal hooks:** `reload-nginx.sh` is shared by both modes; `restart-x-ui.sh` is created only in `full` mode (x-ui reads its cert only at startup).
- **3x-ui upstream changes** (installer env vars, CLI flags, API) can break `full` mode, since it always installs the latest release. Check against the current 3x-ui source when touching that code.

## Keeping README in sync

`README.md` duplicates script behavior in several tables: the parameter list (must match the `case` in arg parsing and `usage()`), the menu and the questions asked in `full` mode, the "files created" table, the 3x-ui instructions, and the troubleshooting section (which quotes the script's error messages). When changing flags, paths, defaults, or error text, update both. Example domain throughout is `nl2.proxhub.ru`.

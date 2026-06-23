# cct — Claude Code multi-account switcher

[한국어](README.md) · **English**

Switch between multiple Claude subscription accounts with a single `cct <label>`. Each account's long-lived OAuth token is kept locally and injected at launch. **Works on macOS / Linux / WSL2. Not a proxy (env-var injection).**

## Install (any PC)

**One-liner** (fastest):
```sh
curl -fsSL https://raw.githubusercontent.com/Bkankim/cct/main/install.sh | bash
```
Or **clone then install** (recommended if you want to read the script first — `curl|bash` runs remote code directly):
```sh
git clone https://github.com/Bkankim/cct.git
cd cct && bash install.sh
```
Then `exec $SHELL` (or a new terminal / `source ~/.claude/cct.sh`).
`install.sh` is idempotent (safe to re-run) and:
- installs `cct.sh` to `~/.claude/cct.sh` and adds a `source` line to your shell rc (`~/.zshrc`/`~/.bashrc`)
- creates a `~/.claude/tokens.env` template (only if missing) with `chmod 600`
- registers `tokens.env` in local + global gitignore (prevents accidental commits)
- ⚠️ does NOT force `cc`/`ㅊㅊ` aliases (avoids clobbering `cc`=C compiler on build machines)

## Commands
| Command | What it does |
|---|---|
| `cct` | Run with the default-label setup-token (`CCT_DEFAULT_LABEL`, default `gv`; no keychain fallback) (`--dangerously-skip-permissions`) |
| `cct <label>` | Run as that account's token (e.g. `cct gv`, `cct pro1`) |
| `cct ls` | List registered accounts |
| `cct add <label>` | Register/update a token (hidden input) |
| `cct check [label]` | Validate token(s) via a real call |
| `cct fp [label]` | Account fingerprint — duplicate detection (same `7d_reset` = same account) |
| `cct help` | Help |

`cct <label>` disables Advisor/nonessential web calls by default to avoid Claude Code 2.1.185+ failures where long-lived `claude setup-token` OAuth tokens are inference-only. Opt back in with `CCT_DISABLE_WEB_FEATURES=0 cct <label>`.

Labels must use lowercase letters, digits, and underscores only (`[a-z0-9_][a-z0-9_]*`). Examples: `gv`, `pro1`, `work_main`.

## Tokens are separate (not in the repo)
Tokens live only in `~/.claude/tokens.env` (plaintext, `600`, keys `CCT_TOKEN_<label>`) and are **never part of the repo** (blocked by `.gitignore`). On a new PC:
- **Option A** — register each account directly:
  ```sh
  claude auth login --claudeai   # confirm the account shown in the browser (the only source of truth)
  claude setup-token             # copy the token
  cct add pro1                   # paste it
  ```
- **Option B** — move your existing `tokens.env` securely to `~/.claude/tokens.env` (prefer a password manager; never plaintext cloud sync), then `chmod 600`.

## Issuing tokens
Use `claude setup-token` (Pro/Max subscription, ~1-year validity). Tokens are machine-independent — works after a PC wipe as long as you kept the value. `sk-ant-oat01-` = subscription OAuth (uses your subscription); `sk-ant-api03-` = API key (metered) — this tool uses the former.

## Security
- `tokens.env` is plaintext → `chmod 600`, **never commit** (auto-gitignored). A token is password-grade; if leaked, re-issue with `claude setup-token`.
- **WSL2**: keep the token file in the Linux home (`~/.claude`). `/mnt/c` paths void `chmod`; use Windows BitLocker for at-rest protection.

## License
MIT — see [LICENSE](LICENSE)

# cct — Portable Claude Account Wallet

[한국어](README.md) · **English**

Authenticate each Claude account once with `claude setup-token`, register the long-lived token in a local wallet, and explicitly select an account with `cct <label>` whenever you need it. Move the wallet securely to use Claude Code in a new environment without repeating browser OAuth login for every account.

**Works on macOS, Linux, and WSL2.** It is not a proxy, orchestrator, automatic router, or load balancer. The user always chooses which account to use.

## Install

Cloning and reviewing the script before installation is recommended.

```sh
git clone https://github.com/Bkankim/cct.git
cd cct
bash install.sh
exec "$SHELL"
```

A one-line install is also available. Because `curl | bash` executes remote code immediately, review it first.

```sh
curl -fsSL https://raw.githubusercontent.com/Bkankim/cct/main/install.sh | bash
```

The installer places `cct.sh` at `~/.claude/cct.sh` and adds a `source` line to the Bash or Zsh startup file. It creates a mode-`600` wallet template only when one is missing. Reinstalling does not overwrite an existing `tokens.env`, backup, active label, or in-progress lock/temp file. Git ignore rules are appended without replacing the user's existing configuration.

## Quick start

Authenticate each account once in a trusted environment and register its setup-token.

```sh
claude auth login --claudeai  # confirm the account shown in the browser
claude setup-token            # copy the issued value
cct add work                  # paste it into the hidden prompt

cct work                      # explicitly select and launch the work account
cct personal                  # switch to the personal account
```

A `setup-token` is the current mechanism for long-lived use, but its lifetime and permanence are not guaranteed. Observed lifetime and provider policy can change. If a token expires, is revoked, or policy changes, issue a new token for that account and replace it with `cct add <label>`.

## Commands

| Command | Behavior | Main exit codes |
|---|---|---|
| `cct [claude args...]` | Launch the sticky active label, or `CCT_DEFAULT_LABEL` (default `gv`) when none is active | Claude exit code; configuration error `1`; usage/label error `2` |
| `cct <label> [claude args...]` | Select that account and forward all Claude arguments | Claude exit code; account missing `1`; label error `2` |
| `cct run <label> [claude args...]` | Explicitly launch even a reserved label such as `rm` | Claude exit code; account missing `1`; usage/label error `2` |
| `cct ls` / `cct list` | List registered accounts without token values | success `0` |
| `cct add <label>` | Register a setup-token or replace an existing one through hidden input | success `0`; cancellation/storage failure `1`; usage error `2` |
| `cct rm <label> [--force]` | Remove the account and annotation after a default `[y/N]` prompt | success `0`; cancellation/failure `1`; usage error `2` |
| `cct rename <old> <new>` | Change the label and active state without changing token bytes | success `0`; collision/failure `1`; usage error `2` |
| `cct status` | Show wallet path/mode/count, active/default label, sticky state, and local Claude version offline | success `0`; usage error `2` |
| `cct doctor` | Diagnose wallet structure, permissions, backup, lock, Claude, and shell as `PASS/WARN/FAIL`, offline | no FAIL `0`; health failure `1`; usage error `2` |
| `cct check [label]` | Validate token(s) with a real Claude call | valid `0`; invalid/unavailable `1`; no token `2`; all-label mode returns `1` if any fail |
| `cct fp [label]` / `cct who [label]` | Compare account fingerprints returned by a real call | A validly formed label returns `0` even when the token is missing or the probe response fails (output-only); invalid label `2` |
| `cct usage [label\|--all]` | Show subscription 5h/7d/7f(premium) utilization and reset from real-call headers (defaults to the active label; premium probe costs ≤32 tokens) | Same as fp: output-only `0`; usage or label error `2` |
| `cct active` | Show the current sticky active label | success `0` |
| `cct refresh` | Re-apply the on-disk active label to the current shell environment (sync after switching in another terminal) | success `0`; missing token `1`; usage error `2` |
| `cct off` | Remove active state and cct auth variables from the current shell | success `0`; state deletion failure `1` |
| `cct help` | Show built-in help | success `0` |

Labels use lowercase ASCII letters, digits, and underscores only: `[a-z0-9_][a-z0-9_]*`. `cct <label>` disables Advisor and nonessential web calls (telemetry, error reporting) by default while keeping auto-update working. Opt in only when needed with `CCT_DISABLE_WEB_FEATURES=0 cct <label>`. The blocking flags (`DISABLE_TELEMETRY` and friends) are generic variable names, so if you already set the same variables yourself, `cct off`, `cct rm` of the active account, `cct refresh` with no active label, and the opt-out clear them in that shell, while a sticky label launch (`cct <label>`) overwrites the same variable with `1` even if you had set it to a different value. To turn auto-update off on purpose, set `DISABLE_AUTOUPDATER=1` yourself; cct never reads or writes it.

`cct <label>` launches claude with `--dangerously-skip-permissions` by default (disable with `CCT_SKIP_PERMS=0`). Pass extra claude flags through `CCT_CLAUDE_FLAGS` (space-separated).

Sticky mode is enabled by default. `cct <label>` remembers the selected account in the current shell and in mode-`600` `~/.claude/cct-active` (override the path with `CCT_ACTIVE_FILE`), so plain `claude` and new terminals keep using it. Run `cct off` to clear it, or set `CCT_STICKY=0` for a launch that does not persist the selection. An already-open terminal does not follow a switch made in another terminal; run `cct refresh` in that shell to re-apply the on-disk active label.

Before launching, `cct <label>` fixes the `hasCompletedOnboarding` flag in the Claude config so an env-token launch does not trigger the interactive login wizard (the flag is reset by `/logout` or updates). Missing, symlinked, or malformed configs are left untouched, and the file mode is preserved. Disable with `CCT_FIX_ONBOARDING=0`.

When applying or clearing an account, cct exports and unsets `ANTHROPIC_OAUTH_TOKEN` alongside `CLAUDE_CODE_OAUTH_TOKEN`, so env-inheriting tools (gjc, aside, ...) follow the active account. gjc keeps stored credentials (agent.db) that take precedence over env tokens, so cct prints a warning on switch/refresh while active anthropic credentials remain there (it never deletes them). Disable with `CCT_GJC_WARN=0`; machines without gjc pass through silently.

For tools that support command-valued secrets instead of env inheritance, the installer also ships the `~/.claude/cct-token.sh` bridge (mode `700`). It prints the active profile's setup-token to stdout and exits non-zero with no output when there is no active profile or token. Example: aside's `models.json` with `"apiKey": "!<home>/.claude/cct-token.sh"` — the tool follows the active account at call time.

## Portability and the OSS boundary

Real credentials live only outside the repository in `~/.claude/tokens.env` (or `CCT_ENV_FILE`). The public repository contains no real wallet, and cloning it grants access to no account. `.gitignore` and the installer's global ignore entries reduce accidents; they are not a security boundary, and users remain responsible for never adding credential files to Git.

Move the wallet through an encrypted channel such as a password manager's secure file transfer.

```sh
mkdir -p ~/.claude
# restore tokens.env from the password manager to ~/.claude/tokens.env
chmod 600 ~/.claude/tokens.env
cct doctor
```

Do not use plaintext cloud sync, chat, email, or a Git commit to move the wallet. Its line format is `CCT_TOKEN_<LABEL>=<SETUP_TOKEN>`; `<SETUP_TOKEN>` is an obvious placeholder, not a credential.

## Storage, backup, and locking

`add`, `rm`, and `rename` write a mode-`600` temporary file in the same directory and finish with an atomic `mv`. Before changing an existing wallet, cct creates a mode-`600` rolling backup at `tokens.env.bak`. Only one rolling backup is retained; keep any longer-term copy in separate encrypted storage.

Concurrent mutations are serialized by a `tokens.env.lock/` directory. If the PID in valid owner metadata is alive, the lock is always busy regardless of the recorded epoch's age. The next mutation can reclaim a lock only when the owner metadata is valid, its PID is dead, and the observed owner still matches during removal. The epoch is diagnostic timing data, not a timeout or reclamation condition. `cct doctor` only reports the condition; it never recovers or modifies files.

If the wallet is damaged, first make sure no cct mutation is still running, then restore the backup.

```sh
cp ~/.claude/tokens.env.bak ~/.claude/tokens.env
chmod 600 ~/.claude/tokens.env
cct doctor
```

Removing or renaming the active account treats wallet and active-state changes as a recoverable transaction. If the active-state write fails, cct restores the verified wallet backup.

## Threat model and operational security

- Treat a setup-token with the same sensitivity as an account password. Revoke or reissue an exposed token for that account, then replace it with `cct add <label>`.
- Portability uses a plaintext wallet. Mode `600` limits ordinary access by other local users, but it does not stop administrators, malware, a compromised user account, or disk theft. Pair it with at-rest encryption such as macOS FileVault, Linux full-disk encryption, or Windows BitLocker.
- `tokens.env.bak` is as sensitive as the primary wallet. Protect it in backups, snapshots, and diagnostic bundles.
- On WSL2, keep the wallet under the Linux home directory at `~/.claude`. Avoid `/mnt/c`, where Linux `chmod 600` semantics may be weakened.
- Do not expose tokens on shared computers, public CI, shell traces (`set -x`), process arguments, or logs. `status` and `doctor` neither print tokens nor validate them over the network.
- Expiry and server-side revocation are normal operational events. cct does not store OAuth refresh state or reauthenticate automatically, so issue a new setup-token for the affected account.

## Intentional non-goals

cct is not an OAuth refresh service, proxy, orchestrator, automatic or quota-based router, load balancer, GUI, or daemon. It does not inspect account state to choose the “best” account and never replaces the user's explicit choice. It also requires neither macOS Keychain nor a separate runtime.

## License

MIT — [LICENSE](LICENSE)

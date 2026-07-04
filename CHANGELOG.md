# Changelog

## Unreleased — portable Claude account wallet

### Product contract

cct is now documented as a **Portable Claude Account Wallet / 휴대용 Claude 계정
지갑**. Authenticate each Claude account once with `claude setup-token`, keep the
long-lived tokens in a local wallet outside Git, and explicitly switch with
`cct <label>` on macOS, Linux, or WSL2. It is not a proxy, orchestrator,
automatic router, or load balancer.

Setup-token lifetime and provider policy may change; this release does not promise
a fixed lifetime or permanent access. Expired, revoked, or exposed credentials must
be reissued for that account and replaced with `cct add <label>`.

| Command | Contract |
|---|---|
| `cct [claude args...]` | Launch the sticky active label, or the default label |
| `cct <label> [claude args...]` | Explicitly select an account and forward Claude arguments |
| `cct run <label> [claude args...]` | Explicitly launch a label even when it is a reserved command |
| `cct ls` / `cct list` | List account labels without token values |
| `cct add <label>` | Register or replace a setup-token through hidden input |
| `cct rm <label> [--force]` | Confirm and remove an account |
| `cct rename <old> <new>` | Rename an account without changing token bytes |
| `cct status` | Show local wallet and Claude metadata without network access |
| `cct doctor` | Report deterministic local `PASS/WARN/FAIL` health checks |
| `cct check [label]` | Validate token(s) through a real Claude call |
| `cct fp [label]` / `cct who [label]` | Compare account fingerprints through a real call |
| `cct active` | Show the sticky active label |
| `cct off` | Clear sticky state and current-shell cct auth variables |
| `cct help` | Show the built-in command contract |

General command errors use `1` for runtime/state failure and `2` for usage or label
errors. `check` uses `0` for valid, `1` for invalid/unavailable, and `2` for a
missing token. `doctor` uses `0` when there is no FAIL, `1` for health failures,
and `2` for invocation misuse.

### Wallet safety

- All wallet mutations use a mode-`600` same-directory temporary file and atomic
  replace, with a mode-`600` rolling backup at `tokens.env.bak`.
- `tokens.env.lock/` serializes changes. Every live owner PID remains busy
  regardless of the recorded epoch's age. A later mutation reclaims only valid
  owner metadata whose PID is dead, after rechecking that the owner still
  matches. The epoch is diagnostic data, not a timeout; diagnostics report lock
  state without recovering or modifying it.
- `rm` and `rename` update wallet and active state as a recoverable transaction.
  An active-state failure restores the verified wallet backup.
- `status` and `doctor` are offline and redact credentials.
- Reinstall preserves the wallet, rolling backup, active state, and in-progress
  lock/temp files. Ignore coverage includes all of those credential-bearing paths.
- The plaintext wallet and backup remain password-sensitive. Use mode `600`,
  full-disk encryption, encrypted transfer such as a password manager, and never
  plaintext cloud sync or Git. On WSL2, keep them out of `/mnt/c`.

### Account lifecycle

- Added `cct run <label> [claude args...]`, including a compatibility escape for
  legacy accounts whose labels collide with commands.
- Added confirmed/forced `cct rm` and atomic `cct rename`.
- Added offline `cct status` and deterministic `cct doctor`.

### Security & correctness remediation

Verified-bug remediation across `cct.sh` and `install.sh`.

### Breaking changes

- **`cct check` exit codes** — `check` now returns a non-zero exit code on failure
  (previously always `0`). Per label: `0` valid, `1` invalid/unreachable, `2` no token.
  A full `cct check` (no label) returns `1` if **any** account has a problem, else `0`.
  Wrappers that relied on `cct check` always succeeding will change behavior.
- **Bare `cct` uses a setup-token (no keychain fallback)** — running `cct` with no label now
  injects the default label's setup-token (`CCT_DEFAULT_LABEL`, default `gv`) instead of
  clearing the ambient token and falling back to the `claude` keychain / `/login` profile.
  Every `cct` entrypoint now stays on a long-lived `setup-token`, so a stale/expired keychain
  login can no longer surface as a 401. A stale exported `CLAUDE_CODE_OAUTH_TOKEN` is always
  overridden; if the default label has no token, `cct` errors out instead of using the keychain.
- **Sticky active profile (default on)** — `cct <label>` now remembers the chosen label as the
  active profile: it `export`s the token into the current shell, writes the label to a state
  file (`cct-active`, next to `tokens.env`; override with `CCT_ACTIVE_FILE`), and every new shell
  auto-loads it on source. A plain `claude` / `cc` / new terminal keeps using the last selected
  account until you run `cct <other>` or `cct off`. Bare `cct` follows the active profile (falling
  back to `CCT_DEFAULT_LABEL`). Set `CCT_STICKY=0` for the old per-process inline behavior.
- **Strict label rules** — labels must match `[a-z0-9_][a-z0-9_]*`. Dashes, uppercase
  letters, spaces, `@`, and non-ASCII labels are rejected. Labels that collide with a
  subcommand (`help ls list add run rm rename status doctor check fp who off active`)
  are rejected (`use` is still allowed).
  `cct`, `cct check`, and `cct fp` now apply the same validation, so invalid labels cannot
  alias an existing normalized token key.

### Migration

If your existing `tokens.env` used a dashed or uppercase label, use the normalized lowercase
key form shown by `cct ls` (for example old `a-b` becomes `ab`) or re-add the account under
a clean `[a-z0-9_][a-z0-9_]*` label.

### Fixes

- **install.sh / H1** — no longer overwrites a pre-existing global `core.excludesfile`.
  It reads the current value (guarded so `set -eu` cannot abort on the missing key),
  tilde-expands a stored `~`-path, and appends the ignore patterns to the existing file
  without changing the config; only when none is configured does it set `~/.gitignore_global`.
- **install.sh / local ignore** — no longer overwrites a pre-existing
  `~/.claude/.gitignore`; required patterns are appended only when missing.
- **install.sh / global ignore idempotence** — `tokens.env` and `.claude/tokens.env` are
  checked independently, so partial pre-existing ignore files are completed without
  duplicate lines.
- **install.sh / N1** — picks the fallback shell rc from `$SHELL` (`zsh` → `~/.zshrc`,
  else `~/.bashrc`), guarded for `set -u`, so a fresh zsh machine with no rc files gets the
  `source` line where zsh actually reads it.
- **cct.sh / N5** — `cct add` no longer prints success when the write fails; it creates the
  token-file directory, and gates every success message on the real write result.
- **cct.sh / H2** — the `cct add` update path `chmod 600`s the temp file before `mv`, closing
  the brief world-readable window on multi-user hosts.
- **cct.sh / N3** — a CRLF-pasted token is normalized before duplicate detection and storage,
  so the duplicate-account warning is not silently skipped.
- **cct.sh / N6** — `cct check` probes the real `claude` binary (resolved via `type -P` /
  `whence -p`), immune to a user-defined `claude` shell function/alias, and reports cleanly
  if `claude` is not on `PATH`.
- **cct.sh / set -u** — `cct` and `cct check` can be called without positional arguments
  in `set -u` shells.
- **cct.sh / errexit + pipefail** — expected empty/missing states such as no token,
  no matching label, no duplicate token, or no `claude` binary now print their diagnostics
  instead of aborting early in shells that enable `set -e` or `pipefail`.

### Added

- **Environment knobs** — `CCT_SKIP_PERMS=0` disables `--dangerously-skip-permissions`;
  `CCT_CLAUDE_FLAGS` passes extra flags to `claude`; `CCT_DEFAULT_LABEL` (default `gv`) is the
  fallback label for a bare `cct`; `CCT_STICKY=0` disables the sticky active profile;
  `CCT_ACTIVE_FILE` overrides the active-profile state path.
- **`cct active` / `cct off`** — show or clear the sticky active profile.
- **Claude Code 2.1.185+ token-mode guard** — labeled `cct <label>` launches now
  suppress Advisor/background plugin refresh/nonessential web calls by default because
  `claude setup-token` long-lived OAuth tokens are inference-only in current Claude Code.
  Set `CCT_DISABLE_WEB_FEATURES=0` to opt back in.
- **Test suite** — `tests/cct_test.sh` (behavioral, no network, fake `claude` shim).

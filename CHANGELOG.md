# Changelog

## Unreleased — per-account usage detail

- `cct <label>`, `cct run`, `cct use`, `cct refresh` and new-shell auto-load now pass
  `CCT_LABEL=<label>` alongside the token; `cct off`, removing the active account, and
  `cct refresh` with no active label clear it.
- New `cct-session-hook.sh` (installed to `~/.claude/`, mode `700`): a Claude Code
  SessionStart hook that appends `{ts, session_id, label, source}` to
  `~/.claude/cct-sessions.jsonl` (mode `600`), plus `cwd` when it can be written back
  as JSON safely. No token or conversation content, no stdout, always exit 0.
- `install.sh` registers the hook in `~/.claude/settings.json` idempotently, keeping
  existing settings. Opt out with `CCT_NO_SESSION_HOOK=1`.
- Dashboard: clicking an account card opens `#/account/<label>` backed by
  `GET /api/account?label=&days=[&session=]`: 5h windows with limit-hit time and
  external-usage estimate, 15-minute token timeline, sessions and requests, model and
  project breakdowns. The token DB schema gains `at`/`session`/`project` and
  rate-limit events; existing DBs are rescanned once.
- Dashboard: per-account monthly subscription price (`plan_usd` setting, entered on the
  detail page) shows this month's API-equivalent cost as a multiple of the plan.
- Dashboard: accounts with a running session (last message within 10 minutes) are
  probed every 5 minutes, independent of the global auto-refresh; never within 5 minutes
  of server start. Toggle `active_probe` in the settings menu.
- `cct doctor` accepts other `NAME=value` env lines in the wallet and counts them as
  `other key(s)` instead of failing.

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
| `cct usage [--json] [label\|--all]` | Show subscription 5h/7d/7f(premium) utilization and reset from real-call rate-limit headers; `--json` emits one JSON object per label |
| `cct use <label>` | Switch the sticky active label without launching claude |
| `cct active` | Show the sticky active label |
| `cct refresh` | Re-apply the on-disk active label to the current shell environment |
| `cct off` | Clear sticky state and current-shell cct auth variables |
| `cct help` | Show the built-in command contract |

General command errors use `1` for runtime/state failure and `2` for usage or label
errors. `check` uses `0` for valid, `1` for invalid/unavailable, and `2` for a
missing token. `doctor` uses `0` when there is no FAIL, `1` for health failures,
and `2` for invocation misuse.

### Changed

- **Web-feature block preserves auto-update** - the labeled `cct <label>` web-feature
  block no longer exports `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, which also disabled
  Claude Code auto-update. It now sets the narrower `DISABLE_TELEMETRY`,
  `DISABLE_ERROR_REPORTING`, `DISABLE_BUG_COMMAND`, and `DISABLE_FEEDBACK_COMMAND`
  (alongside the unchanged `CLAUDE_CODE_DISABLE_ADVISOR_TOOL` and
  `CLAUDE_CODE_DISABLE_BACKGROUND_PLUGIN_REFRESH`), so nonessential web calls stay blocked
  while auto-update keeps working. `CCT_DISABLE_WEB_FEATURES=0` still opts back in. Every
  path that applies a label - the default web-feature block, the `CCT_DISABLE_WEB_FEATURES=0`
  opt-out, and the `cct off`/`cct refresh`/`cct rm` clears - also unsets any inherited
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, so a stale flag left by an older cct in a
  long-lived shell can no longer leak into the child process and keep auto-update off.
- **Flag ownership note** - `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`,
  `DISABLE_BUG_COMMAND`, and `DISABLE_FEEDBACK_COMMAND` are generic Claude Code variable
  names, so if you set the same variables yourself, `cct off`, `cct rm` of the active account,
  `cct refresh` with no active label, and `CCT_DISABLE_WEB_FEATURES=0` clear them in that shell,
  while a sticky label launch (`cct <label>`) overwrites the same variable with `1` even if you
  had set it to a different value. To turn auto-update off on purpose, set `DISABLE_AUTOUPDATER=1`
  yourself; cct never reads or writes it.

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
  subcommand (`help ls list add run rm rename status doctor check fp who usage use off active refresh`)
  are rejected.
  `cct`, `cct check`, and `cct fp` now apply the same validation, so invalid labels cannot
  alias an existing normalized token key.
- **`use` is now a subcommand, so it is a reserved label** - `cct use <label>` switches the
  sticky active label without launching claude, which moves `use` into the reserved list:
  `cct add use` is rejected and `cct use` no longer launches that account. A legacy wallet
  that already holds a `use` label keeps its token and stays launchable through
  `cct run use`; `cct rename use <new>` restores plain `cct <label>` access.

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

- **Dashboard provider tracking (GPT·Grok, dashboard v0.3.0)** - the local dashboard can now
  track ChatGPT/Codex (OpenAI) and SuperGrok (xAI) subscription usage next to the Claude
  wallet. Unconnected providers show an OAuth onboarding card (logo + connect button);
  signing in runs the same public PKCE browser flow the official Codex/Grok CLIs use
  (one-shot loopback callback on `localhost:1455` / `127.0.0.1:56121`), stores tokens only
  in `~/.claude/cct-dash-providers.json` (mode 600, rotating refresh persisted immediately),
  and renders 5h/7d (GPT) and weekly-credit (Grok) meters. Usage reads are metadata GETs
  (zero quota consumed) against unofficial internal endpoints and may break if provider
  policy changes; disable with `--no-providers`.
- **Environment knobs** — `CCT_SKIP_PERMS=0` disables `--dangerously-skip-permissions`;
  `CCT_CLAUDE_FLAGS` passes extra flags to `claude`; `CCT_DEFAULT_LABEL` (default `gv`) is the
  fallback label for a bare `cct`; `CCT_STICKY=0` disables the sticky active profile;
  `CCT_ACTIVE_FILE` overrides the active-profile state path.
- **`cct active` / `cct off`** — show or clear the sticky active profile.
- **`cct refresh`** — re-apply the on-disk sticky active label to the current shell,
  so an already-open terminal follows a switch (or `cct off`) made in another terminal.
- **`cct use <label>`** - switch the sticky active label without launching claude, for
  dashboards, scripts, and any caller that only wants to change accounts. It reuses the
  label-launch path exactly: wallet lock, "account changed during selection" guard, and
  atomic mode-`600` replace of `cct-active`, then applies the token to the current shell.
  Requires sticky; with `CCT_STICKY=0` it refuses with `1` because nothing would be stored.
  Missing token or a held lock returns `1` and leaves the previous active state untouched.
- **`cct usage`** — show subscription usage (5h/7d window utilization, reset time,
  time remaining) from `/v1/messages` rate-limit headers via a 1-token probe.
  Setup tokens lack the `user:profile` scope, so the official `/api/oauth/usage`
  endpoint returns 403; response headers are the only usage window available.
  Also renders the premium (fable/opus) 7-day window as a `7f` gauge: the
  `7d_oi` headers only appear on a premium-model probe with Claude Code
  emulation (system prompt + beta + UA), costing ≤32 premium tokens per check;
  on 429 the command falls back to the standard probe and marks `7f` as denied.
- **`cct usage --json`** - machine-readable usage for scripts and dashboards: one JSON
  object per label (NDJSON) on stdout, with no header line, no blank separators, and no
  ANSI. Every value is whitelisted before it reaches the line (utilization as a bare
  decimal, reset as an integer, status as `[a-z_]+`, org truncated to 8 characters, probe
  model, HTTP code), and anything that fails validation becomes `null`, so a malformed
  header can never inject a quote into the output. `probe` records the premium response
  (`premium_http`, `denied`, `fallback`) even when the standard fallback probe supplied the
  windows. Exit codes are unchanged: a missing token or failed response is reported as
  `state` (`no_token` / `no_response`) with rc `0`, and only usage or label errors return `2`.
- **Onboarding-flag guard** — before launching, cct sets `hasCompletedOnboarding` to
  true in the Claude config so an env-token launch does not trigger the interactive
  login wizard (the flag is reset by `/logout` or updates). Missing, symlinked, or
  malformed configs are left untouched and the file mode is preserved; disable with
  `CCT_FIX_ONBOARDING=0`.
- **Claude Code 2.1.185+ token-mode guard** — labeled `cct <label>` launches now
  suppress Advisor/background plugin refresh/nonessential web calls by default because
  `claude setup-token` long-lived OAuth tokens are inference-only in current Claude Code.
  Set `CCT_DISABLE_WEB_FEATURES=0` to opt back in.
- **Env-inheriting tool follow-through (gjc/aside)** — applying an account also
  exports `ANTHROPIC_OAUTH_TOKEN` with the same value (cleared on `off`/`refresh`/
  active `rm`; mirrored on `add` rotation and non-sticky inline launches), so tools
  that inherit the environment follow the active cct account. A guard warns on
  switch/refresh when gjc still holds active stored anthropic credentials in its
  agent.db, because stored credentials beat env tokens there; it never deletes them.
  Disable with `CCT_GJC_WARN=0` (DB path override for tests: `CCT_GJC_DB`). The guard
  opens the DB read-only through the system sqlite3 (`/usr/bin`, `/bin` — no PATH
  shims) and rejects dash-prefixed DB paths so they cannot be parsed as options.
- **Token bridge for command-valued secrets** — the installer ships
  `~/.claude/cct-token.sh` (mode `700`, same safe install ceremony as the launcher).
  It prints the active profile's setup-token to stdout and exits non-zero with no
  output when absent, so tools like aside (`models.json`
  `"apiKey": "!<home>/.claude/cct-token.sh"`) follow the active cct account at call
  time. Honors `CCT_ENV_FILE`/`CCT_ACTIVE_FILE` overrides and rejects invalid labels.
- **Test suite** — `tests/cct_test.sh` (behavioral, no network, fake `claude` shim).

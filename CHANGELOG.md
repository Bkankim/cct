# Changelog

## Unreleased — security & correctness remediation

Verified-bug remediation across `cct.sh` and `install.sh`.

### Breaking changes

- **`cct check` exit codes** — `check` now returns a non-zero exit code on failure
  (previously always `0`). Per label: `0` valid, `1` invalid/unreachable, `2` no token.
  A full `cct check` (no label) returns `1` if **any** account has a problem, else `0`.
  Wrappers that relied on `cct check` always succeeding will change behavior.
- **Bare `cct` clears the ambient token** — running `cct` with no label now removes any
  inherited `CLAUDE_CODE_OAUTH_TOKEN` before launching `claude`, so it truly uses the
  "currently authenticated profile" as documented (instead of a stale exported token).
- **Strict label rules** — labels must match `[a-z0-9_][a-z0-9_]*`. Dashes, uppercase
  letters, spaces, `@`, and non-ASCII labels are rejected. Labels that collide with a
  subcommand (`help ls list add check fp who`) are rejected (`use` is still allowed).
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

### Added

- **Environment knobs** — `CCT_SKIP_PERMS=0` disables `--dangerously-skip-permissions`;
  `CCT_CLAUDE_FLAGS` passes extra flags to `claude`.
- **Claude Code 2.1.185+ token-mode guard** — labeled `cct <label>` launches now
  suppress Advisor/background plugin refresh/nonessential web calls by default because
  `claude setup-token` long-lived OAuth tokens are inference-only in current Claude Code.
  Set `CCT_DISABLE_WEB_FEATURES=0` to opt back in.
- **Test suite** — `tests/cct_test.sh` (behavioral, no network, fake `claude` shim).

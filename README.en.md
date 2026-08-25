# dsh-upgrade-toolkit

> 中文 | English

![GitHub stars](https://img.shields.io/github/stars/TOBYCAI/dsh-upgrade-toolkit?style=flat-square&color=facc15)
![Downloads](https://img.shields.io/github/downloads/TOBYCAI/dsh-upgrade-toolkit/total?style=flat-square&color=14b8a6)
![License](https://img.shields.io/badge/license-MIT-3b82f6?style=flat-square)
![daily compat](https://img.shields.io/github/actions/workflow/status/TOBYCAI/dsh-upgrade-toolkit/compat.yml?branch=main&label=daily-compat&style=flat-square)
![Script](https://img.shields.io/badge/type-shell--toolkit-4d6bfe?style=flat-square)

One-command management for upgrading **DeepSeek Harness (DSH)**'s "shared install (runtime)" and "desktop shell", and fixing the common breakages that follow an upgrade (shell overwrites runtime, pnpm blocked by a safe-delete guard).

## Why this exists

From a certain version, DSH Desktop became a "shell": the App bundle no longer embeds the full `@deepseek-ai/dsh*`, and instead relies on `~/.dsh/runtime` (shared install) for the upstream Harness. This creates two long-term pain points:

1. **Shell upgrades overwrite the runtime** — on launch, `healProfilesModuleFallback()` re-symlinks `~/.dsh/profiles/node_modules/@deepseek-ai/*` based on the App bundle's dependency closure; if a future shell re-bundles dsh, your runtime upgrades and patches are silently overwritten.
2. **pnpm upgrades / plugin installs get blocked** — if you launch `dsh web` from a host terminal such as WorkBuddy / CodeBuddy, the host injects `CODEBUDDY_SAFE_DELETE_*` env vars, causing pnpm's temp-dir cleanup to hit a bulk-delete confirmation (`SAFE_DELETE_BULK_CONFIRM_REQUIRED`) that cannot be answered in a non-interactive context.

This toolkit codifies the **reliable fixes** for the above into reusable scripts.

## Advantages

Why use this toolkit instead of "manually upgrade, then firefight when it breaks"?

- **Runtime stays authoritative — always.** `pin-runtime.sh` symlinks the shell's and profiles' `@deepseek-ai/*` to the runtime, so the desktop heal resolves straight down to it. Even if a future shell re-bundles dsh into the App, your runtime upgrades and patches **won't be silently overwritten** — a restart recovers them.
- **Shell and runtime are decoupled and independently upgradeable.** `dsh-manage.sh` splits "upgrade runtime" and "upgrade shell" into two separate commands that never step on each other: the shell pulls from GitHub Releases (backup + replace), the runtime does a clean pnpm reinstall — no cross-contamination.
- **Upgrades no longer die inside pnpm.** The toolkit detects the host-injected `CODEBUDDY_SAFE_DELETE_*` guard and unsets it when launching web, eliminating the `SAFE_DELETE_BULK_CONFIRM_REQUIRED` failure that plagues plugin updates in non-interactive host terminals.
- **Know the pitfalls before you upgrade.** The `scan` subcommand scans installed LLM adapters against the runtime dsh version's semver range and predicts whether upgrading to `@next`/`@latest` falls outside compatibility; `check --cron` is report-only and can be wired into a daily cron.
- **One-command self-check and rollback.** `doctor` self-checks symlink targets / backup dirs / guard vars / versions; `rollback` restores from `bundle-bak-*` / `shell-bak-*` in one step, so a bad upgrade stops being a crisis.
- **Cross-platform, zero hard-coding.** Every path is parameterized via `DSH_HOME` / `DSH_APP` / `DSH_PNPM` etc. — full features on macOS, core features on Linux/others. Scripts pass `bash -n` / `node --check` with no mystery absolute paths.
- **Idempotent, auditable, reversible.** Pinning keeps `bundle-bak-<timestamp>/` real dirs for rollback; patches skip already-applied files via markers; every action's root cause is documented in the README — not a black-box one-click script.
- **Open source, MIT, forkable.** The whole solution is a set of readable shell/node scripts with no build step; easier to modify than to read the docs.

## Compatibility matrix (plugin / version vs DSH version)

Check this before upgrading DSH: which plugin breaks on which DSH version. ⚠️ means the web fails to start or a feature breaks on that combo, and you can catch it early with this toolkit's `scan`/`pin` or wait for upstream.

| Plugin (pkg) | Incompatible DSH version | Symptom | Root cause | Status / Fix |
|------|------|------|------|------|
| `@liustack/modlens` | `≤ 3.23.0` | old versions crash when rc.2 enforces `prepareCall` | rc.2 introduced an adapter API change; old modlens didn't implement `prepareCall` | ✅ **modlens ≥ 3.23.x fixes this natively** — just upgrade, no patch needed |
| Any third-party (very old) LLM adapter plugin | didn't catch up to rc.2 contract | may throw `adapter.<method> is not a function` | rc.2 unified the adapter interface contract; very old plugins didn't catch up | ⚠️ Scan installed adapters' dsh version range with `bin/scan-adapters.mjs`; upgrade the plugin to a version supporting rc.2 |
| `@deepseek-ai/dsh` itself | `0.1.1-rc.2` (with an old shell) | runtime silently overwritten / patches lost after a shell update | shell re-bundles dsh, heal closure re-points profiles symlinks back to the shell | ✅ Pin runtime as authority with `pin-runtime.sh` |
| Desktop shell (`DSH Desktop.app`) | After any runtime upgrade | shell-bundled version drifts from runtime version | shell and runtime are decoupled and must be upgraded separately | ✅ Upgrade the shell alone with `dsh-manage.sh shell` |

**How to read the table**:

- The **DSH version** is the version of `@deepseek-ai/dsh` inside `~/.dsh/runtime` (check with `bin/dsh-manage.sh status`). The shell App version is a separate thing — the two are decoupled.
- rc.2 **used to be** a breaking adapter interface change (every LLM adapter had to implement `prepareCall` and other new methods), but the popular plugin `@liustack/modlens` has fixed it natively since **≥ 3.23.x**; for any other old plugin, `bin/scan-adapters.mjs` surfaces the compatibility risk ahead of time.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  DSH Desktop.app (shell)                                     │
│   app.asar.unpacked/node_modules/@deepseek-ai/*  ──symlink─┐ │
└───────────────────────────────────────────────────────────┼─┘
                                                              │ (pin-runtime.sh pins it)
                                                              ▼
┌─────────────────────────────────────────────────────────────┐
│  ~/.dsh/runtime/node_modules/@deepseek-ai/*   ◄── authority  │
│   (where you upgrade via pnpm and apply patches)            │
└─────────────────────────────────────────────────────────────┘
                                                              │ heal resolves down the chain
                                                              ▼
┌─────────────────────────────────────────────────────────────┐
│  ~/.dsh/profiles/node_modules/@deepseek-ai/*  ──symlink─► runtime│
│   (resolved here by dsh-app-boot heal on launch)           │
└─────────────────────────────────────────────────────────────┘
```

`pin-runtime.sh` symlinks the shell's and profiles' `@deepseek-ai/*` to the runtime, so heal always lands on the runtime — **runtime stays authoritative, the shell can't overwrite it**.

## File layout

```
dsh-upgrade-toolkit/
├── README.md / README.en.md
├── LICENSE                    # MIT
├── .gitignore
├── bin/
│   ├── pin-runtime.sh         # Pin runtime as authority (shell/profile symlinks → runtime)
│   ├── dsh-manage.sh          # Unified: runtime/shell upgrade · web · status · doctor · rollback · scan · check
│   ├── verify-heal.mjs        # Verify key packages still resolve to runtime after heal
│   └── scan-adapters.mjs      # Scan installed LLM adapters vs runtime dsh version compatibility
└── docs/
    └── PROMOTION.md           # Channel-by-channel submission list and copy templates
```

## Install

```bash
# Option 1: git clone (recommended)
git clone https://github.com/TOBYCAI/dsh-upgrade-toolkit.git
chmod +x dsh-upgrade-toolkit/bin/*.sh
```

Option 2: download the `dsh-upgrade-toolkit-src.zip` source package from [Releases](https://github.com/TOBYCAI/dsh-upgrade-toolkit/releases) and extract it.

Scripts adapt to your paths via `DSH_HOME` etc. — no hard-coded absolute paths.

## Usage

```bash
# 1) First time / after a shell upgrade: pin runtime as authority
bin/pin-runtime.sh

# 2) Upgrade runtime (interactively confirm @next / @latest)
bin/dsh-manage.sh update
# or non-interactively to a specific version:
bin/dsh-manage.sh update-runtime 0.1.1-rc.2

# 3) Upgrade the desktop shell (dsh-manage.sh auto-downloads the universal dmg from DSH Desktop's GitHub Releases, backs up then replaces)
bin/dsh-manage.sh shell

# 4) Launch web (auto-unloads safe-delete guard so pnpm isn't blocked)
bin/dsh-manage.sh web

# 5) Verify key packages still point to runtime after heal
node bin/verify-heal.mjs

# Show current versions and available updates
bin/dsh-manage.sh status

# Scan installed adapters vs runtime compatibility before upgrading (predicts if @next/@latest falls out of range)
bin/dsh-manage.sh scan
# Report-only mode (wire into crontab for daily self-check; changes nothing)
bin/dsh-manage.sh check --cron
# Self-check the current environment (symlinks / backups / guards / versions)
bin/dsh-manage.sh doctor
# Roll back from the most recent backup: runtime / shell / all
bin/dsh-manage.sh rollback runtime
# Preview the dependency tree that would change, without executing
bin/dsh-manage.sh update --dry-run
```

### Subcommand reference

| Subcommand | What it does | Touches files? |
|------------|--------------|----------------|
| `status` | Show runtime / shell / guard vars / installed adapter versions | read-only |
| `update [--dry-run]` | Upgrade runtime (`--dry-run` previews dependency-tree changes) | write (dry-run: read-only) |
| `update-runtime <ver>` | Single-step non-interactive runtime upgrade to a version | write |
| `shell` | Upgrade the desktop shell (download, backup, replace; Linux/Windows framework in place, marked unverified) | write |
| `web` | Launch web (auto-unload safe-delete guard so pnpm isn't blocked) | launches process |
| `scan` | Scan installed LLM adapters vs runtime dsh version semver range | read-only |
| `check [--cron]` | Report-only self-check (wire into a scheduled task) | read-only |
| `doctor` | Self-check symlink targets / backup dirs / guards / versions | read-only |
| `rollback [runtime\|shell\|all]` | Restore from `bundle-bak-*` / `shell-bak-*` | write |

### Environment variables

| Var | Default | Description |
|-----|---------|-------------|
| `DSH_HOME` | `$HOME/.dsh` | DSH data root |
| `DSH_APP` | `/Applications/DSH Desktop.app` | Shell App path (macOS) |
| `DSH_APP_PKG` | auto | Shell's `@deepseek-ai` dir (for pin-runtime) |
| `DSH_PATCH_YML` | `$DSH_HOME/patches/enable-skills.yml` | `--patch` file for web launch |
| `DSH_PNPM` | auto | Explicit pnpm binary |

## Troubleshooting

### `SAFE_DELETE_BULK_CONFIRM_REQUIRED` / pnpm plugin update fails
You launched `dsh web` from a host terminal (WorkBuddy / CodeBuddy) whose injected `CODEBUDDY_SAFE_DELETE_*` makes pnpm's temp cleanup (>50 files) require confirmation that can't be given. **Fix**: launch via `dsh-manage.sh web`, which `env -u` unsets those guard vars (see script comments).

### Runtime overwritten after a shell upgrade
Re-run `bin/pin-runtime.sh` to re-pin. `bundle-bak-<timestamp>/` keeps the replaced real dirs so you can roll back to the "shell-bundled version".

## Platform support

- **macOS**: all features (shell upgrade uses `.app` + `hdiutil`).
- **Linux**: `update` / `pin` / `web` / `verify-heal` / `scan` / `doctor` / `check` all work; the shell-upgrade framework is in place (download tarball, backup, replace) but **unverified on real hardware** — confirm the Release asset naming manually first.
- **Windows**: core logic mirrors Linux (shell uses an `.exe` installer framework), **unverified on real hardware**.

## License

[MIT](./LICENSE)

## Promote & submit

Want more DSH users to find this project? See [docs/PROMOTION.md](./docs/PROMOTION.md) — a channel-by-channel submission list, copy-paste post templates, and timing tips (Hacker News / Reddit / CSDN / Juejin / V2EX / Product Hunt).

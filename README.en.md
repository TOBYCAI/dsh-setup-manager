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

## Compatibility matrix (plugin / version vs DSH version)

Check this before upgrading DSH: which plugin breaks on which DSH version. ⚠️ means the web fails to start or a feature breaks on that combo, and you can catch it early with this toolkit's `scan`/`pin` or wait for upstream.

| Plugin (pkg) | Incompatible DSH version | Symptom | Root cause | Status / Fix |
|------|------|------|------|------|
| `@liustack/modlens` | `≤ 3.23.0` | old versions crash when rc.2 enforces `prepareCall` | rc.2 introduced an adapter API change; old modlens didn't implement `prepareCall` | ✅ **modlens ≥ 3.23.x fixes this natively** — just upgrade, no patch needed |
| Any third-party (very old) LLM adapter plugin | didn't catch up to rc.2 contract | may throw `adapter.<method> is not a function` | rc.2 unified the adapter interface contract; very old plugins didn't catch up | ⚠️ Scan installed adapters' dsh version range with `bin/scan-adapters.mjs`; upgrade the plugin to a version supporting rc.2 |
| `@deepseek-ai/dsh` itself | `0.1.1-rc.2` (with an old shell) | runtime silently overwritten / patches lost after a shell update | shell re-bundles dsh, heal closure re-points profiles symlinks back to the shell | ✅ Pin runtime as authority with `pin-runtime.sh` |
| Desktop shell (`DSH Desktop.app`) | After any runtime upgrade | shell-bundled version drifts from runtime version | shell and runtime are decoupled and must be upgraded separately | ✅ Upgrade the shell alone with `dsh-manage.sh shell` |

**How to read the table**:

- The **DSH version** is the version of `@deepseek-ai/dsh` inside `~/.dsh/runtime` (check with `dsm status`). The shell App version is a separate thing — the two are decoupled.
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
```

## Install

```bash
# Option 1: git clone (recommended)
git clone https://github.com/TOBYCAI/dsh-upgrade-toolkit.git
chmod +x dsh-upgrade-toolkit/bin/*.sh
```

Option 2: download the `dsh-upgrade-toolkit-src.zip` source package from [Releases](https://github.com/TOBYCAI/dsh-upgrade-toolkit/releases) and extract it.

Scripts adapt to your paths via `DSH_HOME` etc. — no hard-coded absolute paths.

### Add the dsm shortcut alias (recommended)

Add the line below to your shell rc (`~/.zshrc` or `~/.bashrc`) so every command can use `dsm` instead of `bin/dsh-manage.sh`:

```bash
# change the path to wherever you actually cloned / extracted the toolkit
echo 'alias dsm="bash $HOME/dsh-upgrade-toolkit/bin/dsh-manage.sh"' >> ~/.zshrc
source ~/.zshrc
```

Once set, the examples below shorten to `dsm status` / `dsm update` / `dsm web` / `dsm doctor` ….

### First-time DSH install (one-click, both ends)

The "Install" above installs **this toolkit**. To set up DSH from scratch on a machine that has never had it (desktop shell + web runtime), use the `install` subcommand. It will:

1. Download and install the desktop shell from DSH Desktop's GitHub Releases per platform (macOS `.app` / Linux `AppImage`·`tar` / Windows `.exe` — **Linux/Windows shell install is marked unverified on real hardware**);
2. Bootstrap the web runtime: `pnpm`/`npm` install `@deepseek-ai/dsh` into `~/.dsh/runtime` (same mechanism as `update-runtime`, but building the dir from zero), and create a symlink at `~/.dsh/bin/dsh`;
3. Auto `pin` (runtime as authority) + `doctor` (take over with a self-check).

```bash
# One-click dual-end install (shell + runtime + pin + doctor)
dsm install
# pin a runtime version / install only one end / preview first
dsm install --runtime 0.1.1-rc.2
dsm install --no-shell      # runtime only (shell already installed manually)
dsm install --no-runtime     # desktop shell only
dsm install --dry-run        # report what it would do, change nothing
```

> ⚠️ The runtime bootstrap directory layout depends on DSH upstream conventions; it is verified on macOS. If `doctor` reports FAIL on another machine, fix per its output and re-run `pin`. Before `dsh web`, add `export PATH="$HOME/.dsh/bin:$PATH"` to your shell rc (the script reminds you after install).

**After install you are in maintenance mode**: all later upgrades and self-checks reuse the same commands — `dsm install` (skips if already installed) / `dsm update` (runtime) / `dsm shell` (shell) / `dsm web` (launch) / `dsm doctor` (self-check) / `dsm rollback` / `dsm scan` (pre-upgrade compat) / `dsm check` (scheduled report). A machine only needs `dsm install` once.

**Robustness notes**: the read-only commands `status` / `check` / `scan` / `doctor` **do not crash even when DSH is not yet installed or `dsh` is off PATH** — version probing degrades gracefully to `?` / a report instead of aborting. `doctor`'s symlink check is **version-agnostic**: the checklist is taken dynamically from the `@deepseek-ai` packages that actually exist in the runtime, so app-only packages (absent from runtime, correctly sourced from the shell) are never false-positive. The installed version is read from `~/.dsh/runtime/.../dsh/package.json` first (no PATH dependency, not swallowed by stderr), falling back to `dsh --version`.

## Usage

```bash
# 1) First time / after a shell upgrade: pin runtime as authority
dsm pin

# 2) Upgrade runtime (interactively confirm @next / @latest)
dsm update
# or non-interactively to a specific version:
dsm update-runtime 0.1.1-rc.2

# 3) Upgrade the desktop shell (dsh-manage.sh auto-downloads the universal dmg from DSH Desktop's GitHub Releases, backs up then replaces)
dsm shell

# 4) Launch web (auto-unloads safe-delete guard so pnpm isn't blocked)
dsm web

# 5) Verify key packages still point to runtime after heal
node bin/verify-heal.mjs

# Show current versions and available updates
dsm status

# Scan installed adapters vs runtime compatibility before upgrading (predicts if @next/@latest falls out of range)
dsm scan
# Report-only mode (wire into crontab for daily self-check; changes nothing)
dsm check --cron
# Self-check the current environment (symlinks / backups / guards / versions)
dsm doctor
# Roll back from the most recent backup: runtime / shell / all
dsm rollback runtime
# Preview the dependency tree that would change, without executing
dsm update --dry-run
```

### Subcommand reference

| Subcommand | What it does | Touches files? |
|------------|--------------|----------------|
| `install` | First-time setup: install shell + bootstrap runtime + auto pin + doctor | writes (first install) |
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
You launched `dsh web` from a host terminal (WorkBuddy / CodeBuddy) whose injected `CODEBUDDY_SAFE_DELETE_*` makes pnpm's temp cleanup (>50 files) require confirmation that can't be given. **Fix**: launch via `dsm web`, which `env -u` unsets those guard vars (see script comments).

### Runtime overwritten after a shell upgrade
Re-run `dsm pin` to re-pin. `bundle-bak-<timestamp>/` keeps the replaced real dirs so you can roll back to the "shell-bundled version".

## Platform support

- **macOS**: all features (shell upgrade uses `.app` + `hdiutil`).
- **Linux**: `update` / `pin` / `web` / `verify-heal` / `scan` / `doctor` / `check` all work; the shell-upgrade framework is in place (download tarball, backup, replace) but **unverified on real hardware** — confirm the Release asset naming manually first.
- **Windows**: core logic mirrors Linux (shell uses an `.exe` installer framework), **unverified on real hardware**.

## License

[MIT](./LICENSE)

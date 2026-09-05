# dsh-setup-manager

> 中文 | English

![GitHub stars](https://img.shields.io/github/stars/TOBYCAI/dsh-setup-manager?style=flat-square&color=facc15)
![Downloads](https://img.shields.io/github/downloads/TOBYCAI/dsh-setup-manager/total?style=flat-square&color=14b8a6)
![License](https://img.shields.io/badge/license-MIT-3b82f6?style=flat-square)
![daily compat](https://img.shields.io/github/actions/workflow/status/TOBYCAI/dsh-setup-manager/compat.yml?branch=main&label=daily-compat&style=flat-square)
![Script](https://img.shields.io/badge/type-shell--toolkit-4d6bfe?style=flat-square)

**One-stop install, upgrade, and maintenance for DeepSeek Harness (DSH)** — the desktop shell and web share a single `~/.dsh/runtime` engine, so one upgrade updates both ends, and the desktop opens with the latest plugins for the current runtime. This toolkit codifies that "single-engine, dual-end" model into reusable scripts, and fixes common upgrade breakages: shell overrides, safe-delete interference, missing native modules, and half-installed runtimes.

Starting with v1.11.0, arbitrary dependency lifecycle scripts remain disabled by default. Native addons required for DSH boot are built only through a strict name/version/script allowlist and then loaded under the current Node/CPU ABI. Every runtime upgrade creates a recoverable transaction; install failure, version mismatch, native verification failure, Ctrl-C, or terminal interruption restores the previous runtime.

> **The ideal state this toolkit guarantees**
> - Single engine for both ends: the desktop shell and web both symlink to the same `~/.dsh/runtime` — no two independent copies.
> - One upgrade, both ends in sync: `dsm update` upgrades the runtime, and the desktop and web pick it up together.
> - Desktop stays current: the plugin profile is shared across both ends via `~/.dsh/profiles`, so the desktop opens with the latest plugins for the current runtime.
> - Shell upgrades can't break it: `dsm doctor` verifies, and `dsm pin` fixes it in one command if something drifts.

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
| `fs-ext@2.1.1` | `0.1.3-alpha.1` source install | boot fails with `Cannot find module './build/Release/fs_ext.node'` | lifecycle scripts were disabled for supply-chain safety, but the required native addon was not built separately | ✅ v1.11.0 allowlist-builds and load-verifies it with rollback; run `dsm repair-native` for an existing install |
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
dsh-setup-manager/
├── README.md / README.en.md
├── LICENSE                    # MIT
├── .gitignore
├── bin/
│   ├── pin-runtime.sh         # Pin runtime as authority (shell/profile symlinks → runtime)
│   ├── dsh-manage.sh          # Unified: runtime/shell upgrade · web · status · doctor · rollback · scan · check
│   ├── verify-heal.mjs        # Verify key packages still resolve to runtime after heal
│   ├── check-native-addons.mjs # Check/allowlist-repair native addons required at boot
│   ├── scan-adapters.mjs      # Scan installed LLM adapters vs runtime dsh version compatibility
│   └── scan-plugin-api.mjs    # Statically diff plugins' runtime API imports to pre-check startup-breaking conflicts
│   └── check-desktop.mjs      # Statically pre-check Desktop↔shared-runtime compatibility (asar manifest diff + app-code API imports)
└── docs/
```

## Install

Both options yield a `dsh-setup-manager/` directory (containing `bin/dsh-manage.sh`). You can clone or extract it anywhere.

```bash
# Option 1: git clone (recommended)
git clone https://github.com/TOBYCAI/dsh-setup-manager.git
cd dsh-setup-manager
chmod +x bin/*.sh

# Option 2: download the source package from Releases (also extracts to dsh-setup-manager/)
# download dsh-setup-manager-src.zip from https://github.com/TOBYCAI/dsh-setup-manager/releases
unzip dsh-setup-manager-src.zip
cd dsh-setup-manager
chmod +x bin/*.sh
```

Scripts adapt to your paths via `DSH_HOME` etc. — no hard-coded absolute paths; in the alias below, change the path to wherever you actually cloned / extracted the toolkit.

### Add the dsm shortcut alias (recommended)

Add the line below to your shell rc (`~/.zshrc` or `~/.bashrc`) so every command can use `dsm` instead of `bin/dsh-manage.sh`:

```bash
# change the path to wherever you actually cloned / extracted the toolkit
echo 'alias dsm="bash $HOME/dsh-setup-manager/bin/dsh-manage.sh"' >> ~/.zshrc
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

**After install you are in maintenance mode**: all later upgrades and self-checks reuse the same commands — `dsm install` (skips if already installed) / `dsm update` (runtime) / `dsm shell` (shell) / `dsm web` (launch) / `dsm doctor` (self-check) / `dsm rollback` / `dsm cleanup` (clear backups) / `dsm scan` (pre-upgrade compat) / `dsm check` (scheduled report). A machine only needs `dsm install` once.

**Robustness notes**: the read-only commands `status` / `check` / `scan` / `doctor` do not silently abort when DSH is absent, `dsh` is off PATH, or an update service is temporarily unavailable. `doctor` now also loads boot-critical native addons and directs broken/ABI-mismatched installs to `repair-native`. Installed versions are read from the runtime package first, then fall back to `dsh --version`.

## Usage

```bash
# 1) First time / after a shell upgrade: pin runtime as authority
dsm pin

# 2) Upgrade runtime (interactively confirm @next / @latest)
dsm update
# or non-interactively to a specific version:
dsm update-runtime 0.1.1-rc.2
# or build from official GitHub source (for versions npm hasn't published yet, e.g. alpha; no arg probes the latest dsh-v* tag):
dsm update-src
dsm update-src 0.1.2-alpha.1

# ⚠ Before any upgrade, dsm shows a disk-space estimate: the npm channel reports
#   the package size, official dependency count and your current runtime footprint
#   as a reference (plus a pnpm store note); the source channel reports the cached
#   source tree (reused when present, no re-clone) or a 1-2 GB post-build warning;
#   the shell channel reports the dmg download size plus backup. When free space
#   is under 2x the estimate it suggests running `dsm cleanup` first.

# 3) Upgrade the desktop shell (dsh-manage.sh auto-downloads the universal dmg from DSH Desktop's GitHub Releases, backs up then replaces)
dsm shell

# 4) Launch web (auto-unloads safe-delete guard so pnpm isn't blocked)
dsm web

# 5) Verify key packages still point to runtime after heal
node bin/verify-heal.mjs

# Show current versions and available updates
dsm status

# Scan installed adapters vs runtime compatibility before upgrading (incl. static pre-check of plugin↔runtime API imports, predicts startup-breaking conflicts)
dsm scan
# Report-only mode (wire into crontab for daily self-check; changes nothing); includes two compatibility checks:
#   - Plugin API: whether named exports imported by plugins still exist in runtime (a miss crashes dsh web at startup)
#   - Desktop compatibility: diff between Desktop's asar manifest and runtime packages, plus whether named
#     exports imported by Desktop app code still exist (catches both runtime-upgrade failure modes up front)
dsm check --cron
# Self-check the current environment (symlinks / backups / guards / versions)
dsm doctor

# rebuild only audited, boot-critical native addons and verify they load
dsm repair-native
# Roll back from the most recent backup: runtime / shell / all
dsm rollback runtime
# Interactively clean up backups (lists bundle-bak-*/shell-bak-*, choose what to delete / keep; --dry-run just lists)
dsm cleanup
dsm cleanup --dry-run
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
| `update-src [<ver>]` | Build & install from official GitHub source (for versions not yet on npm; no arg probes the latest dsh-v* tag) | write |
| `shell` | Upgrade the desktop shell (download, backup, replace; Linux/Windows framework in place, marked unverified) | write |
| `web` | Launch web (auto-unload safe-delete guard; statically pre-checks plugin↔runtime API conflicts before launch — blocks on a hit, `--force` bypasses) | launches process |
| `scan` | Scan installed LLM adapters vs runtime dsh version semver range; also statically diff plugins' runtime API imports to pre-check conflicts that would crash startup | read-only |
| `check [--cron]` | Report-only self-check (wire into a scheduled task), incl. plugin & Desktop compatibility | read-only |
| `doctor` | Self-check symlink targets / backup dirs / guards / versions (backups listed with real path + size) | read-only |
| `repair-native` | Allowlist-rebuild and load-test boot-critical native addons; refuses unknown versions or modified install scripts | writes |
| `rollback [runtime\|shell\|all]` | Restore from `bundle-bak-*` / `shell-bak-*` | write |
| `cleanup [--dry-run]` | Interactively clear backups: `bundle-bak-*` / `shell-bak-*` / `runtime-src` source caches (in-use version is protected and cannot be removed) | write (dry-run: read-only) |

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

[MIT](./LICENSE) © TOBYCAI

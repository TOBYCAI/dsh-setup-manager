# dsh-upgrade-toolkit

> 中文 | English

![GitHub stars](https://img.shields.io/github/stars/TOBYCAI/dsh-upgrade-toolkit?style=flat-square&color=facc15)
![Downloads](https://img.shields.io/github/downloads/TOBYCAI/dsh-upgrade-toolkit/total?style=flat-square&color=14b8a6)
![Downloads@latest](https://img.shields.io/github/downloads/TOBYCAI/dsh-upgrade-toolkit/latest/total?style=flat-square&color=14b8a6)
![License](https://img.shields.io/badge/license-MIT-3b82f6?style=flat-square)
![daily compat](https://img.shields.io/github/actions/workflow/status/TOBYCAI/dsh-upgrade-toolkit/compat.yml?branch=main&label=daily-compat&style=flat-square)
![Script](https://img.shields.io/badge/type-shell--toolkit-4d6bfe?style=flat-square)

One-command management for upgrading **DeepSeek Harness (DSH)**'s "shared install (runtime)" and "desktop shell", and fixing the common breakages that follow an upgrade (shell overwrites runtime, pnpm blocked by a safe-delete guard, third-party plugins not adapted to the new adapter API).

## Why this exists

From a certain version, DSH Desktop became a "shell": the App bundle no longer embeds the full `@deepseek-ai/dsh*`, and instead relies on `~/.dsh/runtime` (shared install) for the upstream Harness. This creates three long-term pain points:

1. **Shell upgrades overwrite the runtime** — on launch, `healProfilesModuleFallback()` re-symlinks `~/.dsh/profiles/node_modules/@deepseek-ai/*` based on the App bundle's dependency closure; if a future shell re-bundles dsh, your runtime upgrades and patches are silently overwritten.
2. **pnpm upgrades / plugin installs get blocked** — if you launch `dsh web` from a host terminal such as WorkBuddy / CodeBuddy, the host injects `CODEBUDDY_SAFE_DELETE_*` env vars, causing pnpm's temp-dir cleanup to hit a bulk-delete confirmation (`SAFE_DELETE_BULK_CONFIRM_REQUIRED`) that cannot be answered in a non-interactive context.
3. **Third-party plugins not adapted to the new adapter API** — e.g. rc.2 requires every LLM adapter to implement `prepareCall`; plugins like `@liustack/modlens` that lack it crash the web startup.

This toolkit codifies the **reliable fixes** for the above into reusable scripts.

## Advantages

Why use this toolkit instead of "manually upgrade, then firefight when it breaks"?

- **Runtime stays authoritative — always.** `pin-runtime.sh` symlinks the shell's and profiles' `@deepseek-ai/*` to the runtime, so the desktop heal resolves straight down to it. Even if a future shell re-bundles dsh into the App, your runtime upgrades and patches **won't be silently overwritten** — a restart recovers them.
- **Shell and runtime are decoupled and independently upgradeable.** `dsh-manage.sh` splits "upgrade runtime" and "upgrade shell" into two separate commands that never step on each other: the shell pulls from GitHub Releases (backup + replace), the runtime does a clean pnpm reinstall — no cross-contamination.
- **Upgrades no longer die inside pnpm.** The toolkit detects the host-injected `CODEBUDDY_SAFE_DELETE_*` guard and unsets it when launching web, eliminating the `SAFE_DELETE_BULK_CONFIRM_REQUIRED` failure that plagues plugin updates in non-interactive host terminals.
- **Breaking interface changes have a fallback.** The rc.2 `prepareCall` adapter change breaks third-party plugins on upgrade; the toolkit ships a ready `patches/` pnpm-patch flow that you can pin temporarily and remove in one step once upstream catches up — a clear downgrade path.
- **Cross-platform, zero hard-coding.** Every path is parameterized via `DSH_HOME` / `DSH_APP` / `DSH_PNPM` etc. — full features on macOS, core features on Linux/others. Scripts pass `bash -n` / `node --check` with no mystery absolute paths.
- **Idempotent, auditable, reversible.** Pinning keeps `bundle-bak-<timestamp>/` real dirs for rollback; patches skip already-applied files via markers; every action's root cause is documented in the README — not a black-box one-click script.
- **Open source, MIT, forkable.** The whole solution is a set of readable shell/node scripts with no build step; easier to modify than to read the docs.

## Compatibility matrix (plugin / version vs DSH version)

Check this before upgrading DSH: which plugin breaks on which DSH version. ⚠️ means the web fails to start or a feature breaks on that combo, and you need a `patches/` fix from this toolkit or wait for upstream.

| Plugin (pkg) | Incompatible DSH version | Symptom | Root cause | Status / Fix |
|------|------|------|------|------|
| `@liustack/modlens` | **≤ 3.23.0 on `0.1.1-rc.2`** | web fails with `registration.adapter.prepareCall is not a function` | rc.2 introduced an adapter API change: every LLM adapter must implement `prepareCall(config, signal)`; modlens 3.22.2 / 3.23.0 adapters don't | ⚠️ Temporarily pinned via `patches/modlens-prepareCall.md` (pnpm patch). **Remove the patch once modlens > 3.23.0 supports rc.2 natively** |
| `@liustack/modlens` | `0.1.1-rc.1` and earlier | No known adapter crash (rc.2 is what enforces `prepareCall`) | — | ✅ Compatible |
| Any third-party LLM adapter plugin | `0.1.1-rc.2` | May also throw `adapter.<method> is not a function` | rc.2 unified the adapter interface contract; old plugins didn't catch up | ⚠️ Add the missing method to that plugin following the modlens patch; or pin to rc.1 until upstream adapts |
| `@deepseek-ai/dsh` itself | `0.1.1-rc.2` (with an old shell) | runtime silently overwritten / patches lost after a shell update | shell re-bundles dsh, heal closure re-points profiles symlinks back to the shell | ✅ Pin runtime as authority with `pin-runtime.sh` |
| Desktop shell (`DSH Desktop.app`) | After any runtime upgrade | shell-bundled version drifts from runtime version | shell and runtime are decoupled and must be upgraded separately | ✅ Upgrade the shell alone with `dsh-manage.sh shell` |

**How to read the table**:

- The **DSH version** is the version of `@deepseek-ai/dsh` inside `~/.dsh/runtime` (check with `bin/dsh-manage.sh status`). The shell App version is a separate thing — the two are decoupled.
- rc.2 is a **breaking adapter interface change**, not just modlens: any custom/third-party LLM adapter must implement `prepareCall` and other new methods, or the web won't start.
- Patches are **temporary**: once the plugin ships a version that natively supports the target DSH version, delete `patches/` and the `patchedDependencies` entry in `package.json` to return to a clean dependency tree.

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
│   ├── dsh-manage.sh          # Unified: runtime upgrade / shell upgrade / web launch
│   └── verify-heal.mjs        # Verify key packages still resolve to runtime after heal
└── patches/
    └── modlens-prepareCall.md # rc.2 adapter API compat patch (example)
```

## Install

```bash
git clone <your-repo-url> dsh-upgrade-toolkit
chmod +x dsh-upgrade-toolkit/bin/*.sh
```

Scripts adapt to your paths via `DSH_HOME` etc. — no hard-coded absolute paths.

## Usage

```bash
# 1) First time / after a shell upgrade: pin runtime as authority
bin/pin-runtime.sh

# 2) Upgrade runtime (interactively confirm @next / @latest)
bin/dsh-manage.sh update
# or non-interactively to a specific version:
bin/dsh-manage.sh update-runtime 0.1.1-rc.2

# 3) Upgrade the desktop shell (download universal dmg from GitHub Releases, backup then replace)
bin/dsh-manage.sh shell

# 4) Launch web (auto-unloads safe-delete guard so pnpm isn't blocked)
bin/dsh-manage.sh web

# 5) Verify key packages still point to runtime after heal
node bin/verify-heal.mjs

# Show current versions and available updates
bin/dsh-manage.sh status
```

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

### `registration.adapter.prepareCall is not a function`
A third-party LLM adapter plugin hasn't adapted to the rc.2 interface. Follow `patches/modlens-prepareCall.md` (pnpm patch flow) to add `prepareCall` to that plugin; remove the patch once upstream supports it natively.

### Runtime overwritten after a shell upgrade
Re-run `bin/pin-runtime.sh` to re-pin. `bundle-bak-<timestamp>/` keeps the replaced real dirs so you can roll back to the "shell-bundled version".

## Platform support

- **macOS**: all features (shell upgrade uses `.app` + `hdiutil`).
- **Linux / others**: `update` / `pin` / `web` / `verify-heal` work; `shell` upgrade needs a manual replacement (specify the shell's `@deepseek-ai` dir via `DSH_APP_PKG` when there is no `.app`).

## License

[MIT](./LICENSE)

## Promote & submit

Want more DSH users to find this project? See [docs/PROMOTION.md](./docs/PROMOTION.md) — a channel-by-channel submission list, copy-paste post templates, and timing tips (Hacker News / Reddit / CSDN / Juejin / V2EX / Product Hunt).

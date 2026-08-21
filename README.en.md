# dsh-upgrade-toolkit

> [中文](./README.md) | English

One-command management for upgrading **DeepSeek Harness (DSH)**'s "shared install (runtime)" and "desktop shell", and fixing the common breakages that follow an upgrade (shell overwrites runtime, pnpm blocked by a safe-delete guard, third-party plugins not适配 to the new adapter API).

## Why this exists

From a certain version, DSH Desktop became a "shell": the App bundle no longer embeds the full `@deepseek-ai/dsh*`, and instead relies on `~/.dsh/runtime` (shared install) for the upstream Harness. This creates three long-term pain points:

1. **Shell upgrades overwrite the runtime** — on launch, `healProfilesModuleFallback()` re-symlinks `~/.dsh/profiles/node_modules/@deepseek-ai/*` based on the App bundle's dependency closure; if a future shell re-bundles dsh, your runtime upgrades and patches are silently overwritten.
2. **pnpm upgrades / plugin installs get blocked** — if you launch `dsh web` from a host terminal such as WorkBuddy / CodeBuddy, the host injects `CODEBUDDY_SAFE_DELETE_*` env vars, causing pnpm's temp-dir cleanup to hit a bulk-delete confirmation (`SAFE_DELETE_BULK_CONFIRM_REQUIRED`) that cannot be answered in a non-interactive context.
3. **Third-party plugins not adapted to the new adapter API** — e.g. rc.2 requires every LLM adapter to implement `prepareCall`; plugins like `@liustack/modlens` that lack it crash the web startup.

This toolkit codifies the **reliable fixes** for the above into reusable scripts.

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

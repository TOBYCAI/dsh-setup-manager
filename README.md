# dsh-upgrade-toolkit

> 中文 | [English](./README.en.md)

![GitHub stars](https://img.shields.io/github/stars/TOBYCAI/dsh-upgrade-toolkit?style=flat-square&color=facc15)
![Downloads](https://img.shields.io/github/downloads/TOBYCAI/dsh-upgrade-toolkit/total?style=flat-square&color=14b8a6)
![License](https://img.shields.io/badge/license-MIT-3b82f6?style=flat-square)
![daily compat](https://img.shields.io/github/actions/workflow/status/TOBYCAI/dsh-upgrade-toolkit/compat.yml?branch=main&label=daily-compat&style=flat-square)
![Script](https://img.shields.io/badge/type-shell--toolkit-4d6bfe?style=flat-square)

一键管理 **DeepSeek Harness（DSH）** 的「共享安装（runtime）」与「桌面壳」的升级，并解决升级后常见的破坏性问题（壳覆盖 runtime、pnpm 被安全删除守卫拦截）。

## 为什么需要它

DSH Desktop 从某个版本起变成了一个「壳」：App 包本身不再内嵌完整的 `@deepseek-ai/dsh*`，而是依赖 `~/.dsh/runtime`（共享安装）来提供上游 Harness。这带来两个长期痛点：

1. **壳更新会覆盖 runtime** —— 桌面启动时 `healProfilesModuleFallback()` 会按 App 包的依赖闭包把 `~/.dsh/profiles/node_modules/@deepseek-ai/*` 重新软链接；一旦壳把 dsh 又塞进 App 包，你的 runtime 升级与补丁就被静默覆盖。
2. **pnpm 升级/装插件被拦截** —— 如果你在 WorkBuddy / CodeBuddy 之类宿主的终端里启动 `dsh web`，宿主注入的 `CODEBUDDY_SAFE_DELETE_*` 环境变量会让 pnpm 清理临时目录时触发批量删除确认（`SAFE_DELETE_BULK_CONFIRM_REQUIRED`），非交互环境直接失败。

本工具包把上述问题的**可靠解法**固化成可复用脚本。

## 兼容性矩阵（插件 / 版本 vs DSH 版本）

升级 DSH 前先看这一节：哪些插件在哪个 DSH 版本上会"不适配"。标注 ⚠️ 的意味着该组合下 web 启动或特定功能会崩，可用本工具包的 `scan`/`pin` 提前发现或等上游修复。

| 插件（包名） | 不适配的 DSH 版本 | 现象 | 根因 | 状态 / 解法 |
|------|------|------|------|------|
| `@liustack/modlens` | `≤ 3.23.0` | rc.2 强制 `prepareCall` 时旧版本会崩 | rc.2 引入 adapter API 变更，旧 modlens 未实现 `prepareCall` | ✅ **modlens ≥ 3.23.x 已原生修复**，直接升级即可，无需补丁 |
| 任意第三方（极老旧）LLM adapter 插件 | 未跟进 rc.2 接口契约 | 可能报 `adapter.<method> is not a function` | rc.2 统一了 adapter 接口契约，极老旧插件未跟进 | ⚠️ 用 `bin/scan-adapters.mjs` 扫描已装 adapter 的 dsh 版本范围；缺方法就升级该插件到支持 rc.2 的版本 |
| `@deepseek-ai/dsh` 本体 | `0.1.1-rc.2`（配合旧壳） | 壳更新后 runtime 被静默覆盖、补丁丢失 | 壳内重新捆绑 dsh，heal 闭包把 profiles 软链指回壳 | ✅ 用 `pin-runtime.sh` 钉死 runtime 权威 |
| 桌面壳（`DSH Desktop.app`） | 任意 runtime 升级后 | 壳自带版本与 runtime 版本错位 | 壳与 runtime 解耦后需分别升级 | ✅ 用 `dsh-manage.sh shell` 单独升级壳 |

**读表要点**：

- **DSH 版本** 指 `~/.dsh/runtime` 里 `@deepseek-ai/dsh` 的版本（`bin/dsh-manage.sh status` 可查）；壳 App 版本是另一回事，两者已解耦。
- rc.2 曾是一次**破坏性 adapter 接口变更**（每个 LLM adapter 须实现 `prepareCall` 等新方法），但主流插件 `@liustack/modlens` 已在 **≥ 3.23.x** 原生修复；其余老旧插件用 `bin/scan-adapters.mjs` 扫描即可提前发现兼容风险。

## 架构

```
┌─────────────────────────────────────────────────────────────┐
│  DSH Desktop.app（壳）                                        │
│   app.asar.unpacked/node_modules/@deepseek-ai/*  ──软链──┐    │
└───────────────────────────────────────────────────────────┼──┘
                                                              │ (pin-runtime.sh 钉死)
                                                              ▼
┌─────────────────────────────────────────────────────────────┐
│  ~/.dsh/runtime/node_modules/@deepseek-ai/*   ◄── 权威来源    │
│   （你用 pnpm 升级、打补丁的地方）                            │
└─────────────────────────────────────────────────────────────┘
                                                              │ heal 自愈顺链而下
                                                              ▼
┌─────────────────────────────────────────────────────────────┐
│  ~/.dsh/profiles/node_modules/@deepseek-ai/*  ──软链──► runtime│
│   （桌面启动时由 dsh-app-boot heal 解析到这里）              │
└─────────────────────────────────────────────────────────────┘
```

`pin-runtime.sh` 把 App 包 / profiles 的 `@deepseek-ai/*` 都软链接到 runtime，使 heal 的解析永远落到 runtime —— **runtime 始终权威，壳更新盖不到**。

## 文件结构

```
dsh-upgrade-toolkit/
├── README.md / README.en.md
├── LICENSE                    # MIT
├── .gitignore
├── bin/
│   ├── pin-runtime.sh         # 钉死 runtime 权威（壳/Profile 软链 → runtime）
│   ├── dsh-manage.sh          # 统一管理：runtime/壳升级 · web · status · doctor · rollback · scan · check
│   ├── verify-heal.mjs        # 校验 heal 后关键包是否仍解析到 runtime
│   └── scan-adapters.mjs      # 扫描已装 LLM adapter 与 runtime dsh 版本的兼容性
└── docs/
```

## 安装

```bash
# 方式一：git clone（推荐）
git clone https://github.com/TOBYCAI/dsh-upgrade-toolkit.git
# 或把本目录放到任意位置，例如：
#   ~/Downloads/DSH_dev/published/dsh-upgrade-toolkit
chmod +x dsh-upgrade-toolkit/bin/*.sh
```

方式二：从 [Releases](https://github.com/TOBYCAI/dsh-upgrade-toolkit/releases) 下载 `dsh-upgrade-toolkit-src.zip` 源码包，解压即可。

脚本通过 `DSH_HOME` 等环境变量适配你的实际路径，无需硬编码。

### 首次安装 DSH（一键双端）

上面"安装"指的是**安装这套工具包**。如果你要在一台**还没装过 DSH** 的机器上从零装好 DSH（桌面壳 + web runtime），直接用 `install` 子命令，它会：

1. 按平台从 DSH Desktop 的 GitHub Releases 下载并安装桌面壳（macOS `.app` / Linux `AppImage`·`tar` / Windows `.exe`，**Linux/Windows 壳安装标注未经真机验证**）；
2. 引导 web runtime：在 `~/.dsh/runtime` 用 pnpm/npm 安装 `@deepseek-ai/dsh`（与 `update-runtime` 同一机制，只是从零建目录），并在 `~/.dsh/bin/dsh` 建好软链；
3. 自动 `pin`（钉死 runtime 权威）+ `doctor`（自检接管）。

```bash
# 一键双端安装（壳 + runtime + pin + doctor）
bin/dsh-manage.sh install
# 指定 runtime 版本 / 只装一端 / 先预览
bin/dsh-manage.sh install --runtime 0.1.1-rc.2
bin/dsh-manage.sh install --no-shell        # 只引导 runtime（壳已手动装好）
bin/dsh-manage.sh install --no-runtime       # 只装桌面壳
bin/dsh-manage.sh install --dry-run          # 只报告将做什么，不改动
```

> ⚠️ runtime 引导的目录布局依赖 DSH 上游约定，macOS 上已验证可用；换机器若 `doctor` 报 FAIL，按输出手动修正后重跑 `pin` 即可。`dsh web` 前请把 `export PATH="$HOME/.dsh/bin:$PATH"` 加入你的 shell rc（脚本安装完会提示）。

**安装完即进入维护模式**：之后所有升级与自检都复用同一套命令——`install`（已装则跳过）/ `update`（升 runtime）/ `shell`（升壳）/ `web`（启动）/ `doctor`（自检）/ `rollback`（回滚）/ `scan`（升级前查兼容）/ `check`（定时报告）。一台机器只需 `install` 一次。

**健壮性说明**：`status` / `check` / `scan` / `doctor` 等**只读命令在 DSH 尚未安装、或 `dsh` 不在 PATH 时也不会崩溃**——版本探测失败只降级为 `?` / 优雅报告，不再中断。`doctor` 的软链校验是**版本无关**的：检查清单动态取自 runtime 中真实存在的 `@deepseek-ai` 包，app-only 包（runtime 中没有、本就该来自壳）不会误报。已装版本优先读 `~/.dsh/runtime/.../dsh/package.json`（不依赖 PATH、不被 stderr 吞），缺失时回退 `dsh --version`。

## 使用

```bash
# 1) 首次 / 壳更新后：把 runtime 钉死为权威
bin/pin-runtime.sh

# 2) 升级 runtime（交互确认 @next / @latest 各自版本）
bin/dsh-manage.sh update
# 或单步非交互升级到指定版本：
bin/dsh-manage.sh update-runtime 0.1.1-rc.2

# 3) 升级桌面壳（dsh-manage.sh 自动从 DSH Desktop 的 GitHub Releases 下载 universal dmg，备份后替换）
bin/dsh-manage.sh shell

# 4) 启动 web（自动卸载 safe-delete 守卫，避免 pnpm 被拦截）
bin/dsh-manage.sh web

# 5) 校验 heal 后关键包仍指向 runtime
node bin/verify-heal.mjs

# 查看当前版本与可用更新
bin/dsh-manage.sh status

# 升级前先扫描已装 adapter 与 runtime 的兼容性（预测 @next/@latest 是否掉范围）
bin/dsh-manage.sh scan
# 仅报告模式（可挂 crontab 每天自检，不改动任何东西）
bin/dsh-manage.sh check --cron
# 自检当前环境（软链 / 备份 / 守卫 / 版本）
bin/dsh-manage.sh doctor
# 从最近的备份回滚：runtime / shell / all
bin/dsh-manage.sh rollback runtime
# 升级前预览将变更的依赖树，不实际执行
bin/dsh-manage.sh update --dry-run
```

### 子命令一览

| 子命令 | 作用 | 是否改文件 |
|------|------|------|
| `install` | 首次安装：下载桌面壳 + 引导 runtime + 自动 pin + doctor | 写（首次安装） |
| `status` | 显示 runtime / 壳 / 守卫变量 / 已装 adapter 版本 | 只读 |
| `update [--dry-run]` | 升级 runtime（`--dry-run` 仅预览依赖树变更） | 写（dry-run 只读） |
| `update-runtime <ver>` | 单步非交互升级 runtime 到指定版本 | 写 |
| `shell` | 升级桌面壳（下载备份替换；Linux/Windows 框架已就位，标注未验证） | 写 |
| `web` | 启动 web（自动卸载 safe-delete 守卫，避免 pnpm 被拦截） | 启动进程 |
| `scan` | 扫描已装 LLM adapter 与 runtime dsh 版本的 semver 兼容范围 | 只读 |
| `check [--cron]` | 仅报告模式自检（可挂定时任务） | 只读 |
| `doctor` | 自检软链指向 / 备份目录 / 守卫 / 版本 | 只读 |
| `rollback [runtime\|shell\|all]` | 从 `bundle-bak-*` / `shell-bak-*` 还原 | 写 |

### 环境变量

| 变量 | 默认 | 说明 |
|------|------|------|
| `DSH_HOME` | `$HOME/.dsh` | DSH 数据根目录 |
| `DSH_APP` | `/Applications/DSH Desktop.app` | 壳 App 路径（macOS） |
| `DSH_APP_PKG` | 自动探测 | 壳内 `@deepseek-ai` 目录（pin-runtime 用） |
| `DSH_PATCH_YML` | `$DSH_HOME/patches/enable-skills.yml` | web 启动的 `--patch` 文件 |
| `DSH_PNPM` | 自动探测 | 指定 pnpm 可执行文件 |

## 故障排查

### `SAFE_DELETE_BULK_CONFIRM_REQUIRED` / pnpm 更新插件失败
你在 WorkBuddy / CodeBuddy 终端里启动了 `dsh web`，宿主注入的 `CODEBUDDY_SAFE_DELETE_*` 让 pnpm 清理临时目录（>50 文件）需确认但无法确认。**解法**：用 `dsh-manage.sh web` 启动，它会 `env -u` 卸载这些守卫变量（详见脚本注释）。

### 壳更新后 runtime 被覆盖
重跑 `bin/pin-runtime.sh` 重新钉死。`bundle-bak-<时间戳>/` 保留被替换的真实目录，可据此回滚到「壳自带版本」。

## 适用平台

- **macOS**：全部功能（壳升级走 `.app` + `hdiutil`）。
- **Linux**：`update` / `pin` / `web` / `verify-heal` / `scan` / `doctor` / `check` 全可用；壳升级框架已就位（下载 tarball 备份替换），**未经真机验证**，建议先手动确认 Release asset 命名。
- **Windows**：核心逻辑同 Linux（`shell` 走 `.exe` 安装包框架），**未经真机验证**。

## License

[MIT](./LICENSE)

# dsh-upgrade-toolkit

> 中文 | [English](./README.en.md)

一键管理 **DeepSeek Harness（DSH）** 的「共享安装（runtime）」与「桌面壳」的升级，并解决升级后常见的破坏性问题（壳覆盖 runtime、pnpm 被安全删除守卫拦截、第三方插件未适配新 adapter API）。

## 为什么需要它

DSH Desktop 从某个版本起变成了一个「壳」：App 包本身不再内嵌完整的 `@deepseek-ai/dsh*`，而是依赖 `~/.dsh/runtime`（共享安装）来提供上游 Harness。这带来三个长期痛点：

1. **壳更新会覆盖 runtime** —— 桌面启动时 `healProfilesModuleFallback()` 会按 App 包的依赖闭包把 `~/.dsh/profiles/node_modules/@deepseek-ai/*` 重新软链接；一旦壳把 dsh 又塞进 App 包，你的 runtime 升级与补丁就被静默覆盖。
2. **pnpm 升级/装插件被拦截** —— 如果你在 WorkBuddy / CodeBuddy 之类宿主的终端里启动 `dsh web`，宿主注入的 `CODEBUDDY_SAFE_DELETE_*` 环境变量会让 pnpm 清理临时目录时触发批量删除确认（`SAFE_DELETE_BULK_CONFIRM_REQUIRED`），非交互环境直接失败。
3. **第三方插件未适配新 adapter API** —— 例如 rc.2 要求每个 LLM adapter 实现 `prepareCall`，而 `@liustack/modlens` 等插件缺该方法会直接导致 web 启动崩溃。

本工具包把上述问题的**可靠解法**固化成可复用脚本。

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
│   ├── dsh-manage.sh          # 统一管理：runtime 升级 / 壳升级 / web 启动
│   └── verify-heal.mjs        # 校验 heal 后关键包是否仍解析到 runtime
└── patches/
    └── modlens-prepareCall.md # rc.2 adapter API 兼容补丁说明（示例）
```

## 安装

```bash
git clone <your-repo-url> dsh-upgrade-toolkit
# 或把本目录放到任意位置，例如：
#   ~/Downloads/DSH_dev/published/dsh-upgrade-toolkit
chmod +x dsh-upgrade-toolkit/bin/*.sh
```

脚本通过 `DSH_HOME` 等环境变量适配你的实际路径，无需硬编码。

## 使用

```bash
# 1) 首次 / 壳更新后：把 runtime 钉死为权威
bin/pin-runtime.sh

# 2) 升级 runtime（交互确认 @next / @latest 各自版本）
bin/dsh-manage.sh update
# 或单步非交互升级到指定版本：
bin/dsh-manage.sh update-runtime 0.1.1-rc.2

# 3) 升级桌面壳（从 GitHub Releases 下载 universal dmg，备份后替换）
bin/dsh-manage.sh shell

# 4) 启动 web（自动卸载 safe-delete 守卫，避免 pnpm 被拦截）
bin/dsh-manage.sh web

# 5) 校验 heal 后关键包仍指向 runtime
node bin/verify-heal.mjs

# 查看当前版本与可用更新
bin/dsh-manage.sh status
```

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

### `registration.adapter.prepareCall is not a function`
某个已装的第三方 LLM adapter 插件未适配 rc.2 新接口。按 `patches/modlens-prepareCall.md` 的 pnpm patch 流程给该插件补上 `prepareCall`；上游原生支持后移除补丁。

### 壳更新后 runtime 被覆盖
重跑 `bin/pin-runtime.sh` 重新钉死。`bundle-bak-<时间戳>/` 保留被替换的真实目录，可据此回滚到「壳自带版本」。

## 适用平台

- **macOS**：全部功能（壳升级走 `.app` + `hdiutil`）。
- **Linux / 其他**：`update` / `pin` / `web` / `verify-heal` 可用；`shell` 升级需自行替换壳包（无 `.app` 概念时通过 `DSH_APP_PKG` 指定壳内 `@deepseek-ai` 目录）。

## License

[MIT](./LICENSE)

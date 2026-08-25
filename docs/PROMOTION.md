# 推广与投稿指南（DSH Upgrade Toolkit）

> 一份给维护者/贡献者的「去哪发、怎么发」实操清单。本仓库是 **DeepSeek Harness（DSH）** 的高级运维工具，受众是**已经在使用 DSH 并愿意折腾 runtime / 插件 / 桌面壳**的开发者，不是小白桌面端用户。投稿渠道要精准，别往泛 AI 流量池里硬塞。

## 0. 先搞清楚你的产品定位

| 维度 | 说明 |
|------|------|
| 是什么 | DSH `runtime`（共享安装）与桌面壳的管理 + 升级后破坏性问题的修复工具包 |
| 不是什么 | 不是另一个 DSH 桌面端（那是 `anywhere-labs/deepseek-harness-desktop` 做的事） |
| 解决什么 | 壳覆盖 runtime、pnpm 被 safe-delete 守卫拦截（modlens 的 rc.2 `prepareCall` 问题上游 ≥3.23.x 已修复，无需补丁） |
| 目标受众 | 自己装过 DSH、踩过升级坑、用 WorkBuddy/CodeBuddy 终端跑 `dsh web` 的开发者 |
| 一句话钩子 | “升级 DSH 后 runtime 被壳覆盖、插件崩、pnpm 卡死？这一个工具包全修好。” |

**核心卖点（投稿时反复出现）**：
1. runtime 永远权威，壳更新盖不到
2. 壳与 runtime 解耦，各自独立升级
3. 自动卸掉宿主 safe-delete 守卫，pnpm 升级插件不再失败
4. 升级前 `scan` 先知会踩哪些坑、`doctor` 自检、`rollback` 一键回滚
5. 跨平台、零硬编码、MIT 可 fork

## 1. DSH 生态内部渠道（优先级最高）

这些地方的用户**已经知道 DSH 是什么**，转化率最高。

| 渠道 | 地址 / 入口 | 怎么发 | 备注 |
|------|------|------|------|
| 官方 Harness 仓库 Issues/Discussions | `github.com/deepseek-ai/deepseek-harness` | 在 Discussions 发“show and tell”或“tooling”类帖子，链接本仓库 | 先读社区规范，别发成广告；强调“互补非竞争” |
| DSH 1024Store 插件市场 | 桌面端内置的插件市场（来源 `DSH 1024Store`） | 若 toolkit 能做成可被发现的“工具类插件/来源”，接入市场 Schema | 需符合公开 Schema；适合长期，门槛略高 |
| 社区桌面端仓库 | `github.com/anywhere-labs/deepseek-harness-desktop` | 在 Issues/Discussions 提“升级后 runtime 被覆盖”相关话题并附本工具 | 桌面端用户正是壳/runtime 错位的重灾区 |
| CSDN DeepSeek 技术社区 | `deepseek.csdn.net` | 写一篇《DSH 升级避坑：runtime 被壳覆盖怎么办》并附仓库 | 国内开发者集中，已有 DSH 专题 |
| 掘金 | `juejin.cn` | 技术拆解文：《DeepSeek Harness 升级机制与 runtime 钉死方案》 | 掘金已有近万字 DSH 拆解，用户质量高 |

## 2. 英文开发者社区（蹭 DSH 全球热度）

DSH 8/13 开源后两天 95K stars、Hacker News TOP 1，全球开发者好奇中。

| 渠道 | 入口 | 怎么发 | 备注 |
|------|------|------|------|
| Hacker News | `news.ycombinator.com` | 发一条 “Show HN: A toolkit to safely upgrade DeepSeek Harness runtime/shell (fixes plugin breakage)” | 标题带 “Show HN” + 具体痛点；HN 对 DSH 极其友好 |
| Reddit r/LocalLLaMA | `reddit.com/r/LocalLLaMA` | 发帖介绍 tooling，标签 `[P]`(project) | DSH 讨论最热的子版 |
| Reddit r/DeepSeek | `reddit.com/r/DeepSeek` | 同上 | 官方模型/框架粉丝聚集地 |
| Reddit r/selfhosted | `reddit.com/r/selfhosted` | 强调“本地优先、runtime 自管”角度 | 贴合 self-host 受众 |
| DEV.to | `dev.to` | 写一篇教程文，打 `#deepseek #opensource #showdev` tag | 已有 DSH 相关文章，容易获得阅读 |
| GitHub Trending / Topic | `github.com/topics/deepseek-harness` | 确保 repo topics 含 `deepseek-harness`（已加） | 被 topic 页收录即免费曝光 |

## 3. 中文社区（国内流量）

| 渠道 | 入口 | 怎么发 | 备注 |
|------|------|------|------|
| V2EX | `v2ex.com` 的“分享创造”节点 | 发《做了个 DSH 升级工具包，解决壳覆盖 runtime 和插件崩溃》 | V2EX 对 DSH 讨论热度高 |
| 少数派 | `sspai.com` | 写“效率”/“正版软件”类文章，讲 DSH 本地化运维 | 偏产品向，需包装成使用经验 |
| 知乎 | `zhihu.com` | 回答“DeepSeek Harness 怎么升级/避坑”类问题并附仓库 | 长尾搜索流量大 |
| 微信公众号 | 科技类公众号（如“极客之家”已发过 DSH 桌面端） | 投稿或自运营：《DSH 升级翻车实录与修复工具》 | 触达非技术但关注 AI 的群体 |
| 掘金 / CSDN / 51CTO | 见上 | 技术文 | 已被验证有 DSH 读者 |

## 4. 开源门户 / 榜单

| 渠道 | 入口 | 怎么发 |
|------|------|------|
| Product Hunt | `producthunt.com` | 发产品页，tag: Open Source / Developer Tools / AI；准备首图与一句话 |
| HelloGitHub | `hellogithub.com` | 提交中文开源项目收录 |
|  Awesome 列表 | 如 `awesome-deepseek` / `awesome-harness-engineering` | 提 PR 加入工具清单（注意 awesome-harness-engineering 已存在，是高频流量入口） |

## 5. 投稿时机与节奏

1. **趁热度**：DSH 仍在全球趋势期（8 月开源），现在发 HN / Reddit 最容易获得初始投票。
2. **先内后外**：先在 DSH 生态内部（官方 Discussions、桌面端仓库、CSDN/掘金）立住“互补工具”人设，再外溢到 HN/PH。
3. **内容复用**：一篇掘金/CSDN 长文 → 拆成 HN 标题 + Reddit 帖子 + V2EX 短帖 + 微信公众号，同一素材多平台分发。
4. **持续运营**：每修一个 DSH 新版本的坑（如 rc.3 又改了什么），就发一条“已支持 DSH x.y”的更新帖，保持活跃。

## 6. 可直接套用的文案模板

### Hacker News（Show HN）
```
Show HN: A toolkit to safely upgrade DeepSeek Harness (runtime + shell)

DeepSeek Harness (DSH) ships as a "shell" app that depends on a shared
install (~/.dsh/runtime). Upgrading either one silently breaks the other,
and the host-injected safe-delete guard blocks pnpm plugin updates in
non-interactive terminals.

This MIT toolkit (bash + node, zero hard-coded paths) pins the runtime as
the authority, decouples shell/runtime upgrades, unloads the host
safe-delete guard that blocks pnpm plugin updates, and adds scan/doctor/
rollback so you know the pitfalls and can recover before anything breaks.

https://github.com/TOBYCAI/dsh-upgrade-toolkit
```

### Reddit（r/LocalLLaMA，[P] 项目）
```
[P] dsh-upgrade-toolkit — stop DSH shell upgrades from nuking your runtime

If you self-host DeepSeek Harness and have been bitten by:
- shell update overwriting your runtime + patches
- pnpm plugin update failing with SAFE_DELETE_BULK_CONFIRM_REQUIRED
- a third-party LLM adapter still on a pre-rc.2 interface crashing on launch

...this toolkit pins runtime as authority, splits shell/runtime upgrades,
and includes a ready pnpm patch. MIT, cross-platform.
```

### 中文社区（V2EX / 掘金 引子）
```
做了个 DSH 升级工具包：解决壳覆盖 runtime、pnpm 被守卫拦截、升级前不知会踩哪些坑

DeepSeek Harness 把桌面端做成了“壳”，依赖 ~/.dsh/runtime 提供上游能力。
升级壳之后 runtime 常被静默覆盖（modlens 的 rc.2 prepareCall 问题上游 ≥3.23.x 已修复，无需补丁）。

这个 MIT 工具包把这几类坑的可靠解法固化成脚本：
1. pin-runtime 钉死 runtime 权威
2. 壳/runtime 解耦各自升级
3. 启动 web 时卸掉宿主 safe-delete 守卫
4. scan 预检兼容性 + doctor 自检 + rollback 一键回滚

仓库：https://github.com/TOBYCAI/dsh-upgrade-toolkit
```

## 7. 投稿前检查清单

- [ ] repo 已 public、About 双语、topics 含 `deepseek-harness`（已就绪）
- [ ] README 有清晰的“这是什么 / 不是什么 / 解决什么”（已就绪）
- [ ] 有一个能一键跑起来的 demo 路径（`bin/pin-runtime.sh` 等）
- [ ] 在 DSH 官方 Discussions 先露个脸，建立“互补非竞争”认知
- [ ] 准备好 140 字内的一句话钩子（中英文各一版）
- [ ] 发帖后自己先在评论区答一轮常见问题（为什么不直接用官方？和桌面端什么关系？）

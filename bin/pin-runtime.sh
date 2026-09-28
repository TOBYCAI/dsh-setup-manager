#!/usr/bin/env bash
# pin-runtime.sh — 把 DSH 的「共享安装（runtime）」权威来源钉死，让桌面壳更新盖不到它。
#
# ============================================================================
# 背景 / 问题与解法
# ----------------------------------------------------------------------------
# DSH Desktop 的打包形态**换过一次**，脚本必须分辨（2026-09-10 实测）：
#
#   模式 A「共享软链」（Desktop ≤ 2.0.5）
#     App 包不再内嵌完整的 @deepseek-ai/dsh*，而是依赖 profile 的共享安装
#       ~/.dsh/profiles/node_modules/@deepseek-ai/*
#     来提供上游 Harness。桌面启动时 dsh-app-boot 的 healProfilesModuleFallback()
#     会按 *App 包* 的依赖闭包，把 profiles/node_modules/@deepseek-ai/* 重新软链接到
#     它认为正确的来源；某次壳更新若把 dsh 又塞回 App 包，heal 就会把 profile 链接
#     打回 App 包内版本，覆盖你维护的 runtime —— 升级/补丁前功尽弃。
#     解法（仅此模式需要）：把 App 包内 node_modules/@deepseek-ai/*（runtime 里也存在的）
#     软链到 ~/.dsh/runtime/node_modules/@deepseek-ai/*，让 heal 的 BFS 解析顺着链接落到
#     runtime，profile 链接自然被 heal 指向 runtime。
#
#     【机制现状】dsh 0.1.7-alpha.1 起 dsh-app-boot 已**删除** healProfilesModuleFallback，
#     壳不再在启动时改写 profiles 软链：pin 的结果长期有效，不再有「被壳打回」的风险。
#     本脚本保留模式 A 的处理仅用于旧版 runtime/壳；verify-heal.mjs 会自动降级为静态校验。
#
#   模式 B「自包含」（Desktop ≥ 2.0.7）
#     壳把整棵 node_modules 打进 app.asar 正文（实测 245 个 @deepseek-ai 包、
#     正文 ~167 MB），unpacked 只剩 node-addon-system-* 两个真实目录，**没有软链农场**。
#     壳自带自己的 dsh 副本（2.0.7 = 0.1.5-rc.1），模块解析以 asar 内打包副本为准：
#       · 改写 .app 内软链**无效**（打包条目优先，asar 虚拟层只认清单）；
#       · 而且会改动 .app 资源 —— macOS 代码签名 / 自动更新校验可能因此报错；
#       · 壳与 CLI runtime 是两份**独立**副本，升级 CLI runtime 不影响壳。
#     所以本模式下**跳过**对 App 包的改造，只钉 profiles（CLI / web 侧仍需要）。
#     版本偏差请用 `dsm check`（check-desktop.mjs）查看：它会同时报出壳自带版本与
#     CLI runtime 版本，并在不一致时给出告警。
#
# 模式判定：unpacked 的 @deepseek-ai 下**没有任何软链**、且 app.asar 正文 > 1 MB
#           → 自包含。可用 DSH_APP_SELF_CONTAINED=1/0 强制指定。
#
# 回滚：模式 A 下被替换的 bundle 真实目录备份在 ~/.dsh/bundle-bak-<时间戳>/。
#       想还原为「壳自带版本」：删掉对应软链接、把备份移回原位即可。
#
# 适用：macOS（默认 App 路径 /Applications/DSH Desktop.app）；Linux/其他平台通过
#       环境变量 DSH_APP_PKG 指定壳的 asar 解包目录中的 node_modules/@deepseek-ai。
# ============================================================================
set -u

# ---- 可配置路径（全部可通过环境变量覆盖，便于跨用户 / 跨平台）----
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
RT="$DSH_HOME/runtime/node_modules/@deepseek-ai"

# App 包内 @deepseek-ai 位置：macOS 在 .app/Contents/Resources/app.asar.unpacked/...
# 可用 DSH_APP_PKG 显式指定（指向包含 node_modules/@deepseek-ai 的目录）。
if [ -n "${DSH_APP_PKG:-}" ]; then
  APP="$DSH_APP_PKG"
elif [ -d "/Applications/DSH Desktop.app/Contents/Resources/app.asar.unpacked/node_modules/@deepseek-ai" ]; then
  APP="/Applications/DSH Desktop.app/Contents/Resources/app.asar.unpacked/node_modules/@deepseek-ai"
else
  # 非 macOS 或未安装壳：用一个影子目录，保证 profiles 链接依然钉到 runtime
  APP="$DSH_HOME/_app-shadow/node_modules/@deepseek-ai"
  echo "⚠ 未检测到 DSH Desktop.app，使用影子目录 ${APP}（壳更新后请重新指定 DSH_APP_PKG）。"
fi

PROF="$DSH_HOME/profiles/node_modules/@deepseek-ai"
TS="$(date +%Y%m%d%H%M%S)"
BAK="$DSH_HOME/bundle-bak-$TS"

[[ -d "$RT" ]] || { echo "✗ runtime 不存在: $RT" >&2; exit 1; }

# ---- 壳的打包模式判定（自包含 vs 共享软链）--------------------------------
# 自包含：app.asar 正文 > 1 MB（node_modules 打进 asar）且 unpacked 下无软链农场。
# 该模式下改造 .app 内软链既无效又会改动 app 资源（签名/更新校验），必须跳过。
# 判定逻辑与 dsh-manage.sh 共用 bin/app-mode.sh（可用 DSH_APP_SELF_CONTAINED=1/0 覆盖）。
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [ -f "$_SELF_DIR/app-mode.sh" ]; then
  # shellcheck source=bin/app-mode.sh
  . "$_SELF_DIR/app-mode.sh"
fi
# 兜底：辅助脚本缺失时按「共享软链」处理（历史行为），不阻断脚本
command -v dsh_app_mode >/dev/null 2>&1 || dsh_app_mode() { printf 'shared'; }
command -v dsh_app_mode_why >/dev/null 2>&1 || dsh_app_mode_why() { printf '未加载 app-mode.sh（按共享软链处理）'; }
APP_MODE="$(dsh_app_mode "$APP")"
MODE_WHY="$(dsh_app_mode_why "$APP")"

if [[ "$APP_MODE" = "packed" ]]; then
  echo "ℹ️  检测到桌面壳为「自包含」打包（app.asar 内含完整 node_modules）：跳过改造 .app 内软链。"
  echo "    判定依据：${MODE_WHY}"
  echo "    壳自带自己的 dsh 副本，与 CLI runtime 是两份独立副本；改 .app 资源会破坏签名/更新校验。"
  echo "    运行 dsm check 可查看壳自带版本与 CLI runtime 的版本偏差。"
  mkdir -p "$PROF"
else
  mkdir -p "$APP" "$PROF"
fi

pinned=0
backed=0
# 1) 把 bundle 内部的 @deepseek-ai/* 钉到 runtime（自包含模式除外）
#    - 已是正确软链接   -> 跳过
#    - 是真实目录       -> 备份后替换为软链接
#    - 不存在 / 错误链接 -> 直接创建 / 修正为指向 runtime 的软链接
#    注意条件是「非 packed」而非「= shared」：模式可能为 unknown（无 asar 的
#    非 macOS 布局 / 影子目录），此时沿用历史行为——补全软链，绝不静默跳过。
if [[ "$APP_MODE" != "packed" ]]; then
  for src in "$RT"/*; do
    [[ -e "$src" ]] || continue
    name="$(basename "$src")"
    tgt="$APP/$name"
    if [[ -L "$tgt" ]]; then
      [[ "$(readlink "$tgt")" == "$src" ]] && continue
      rm "$tgt"
    elif [[ -e "$tgt" ]]; then
      mkdir -p "$BAK"
      mv "$tgt" "$BAK/$name"
      backed=$((backed+1))
    fi
    ln -s "$src" "$tgt"
    pinned=$((pinned+1))
  done
fi

# 2) 直接把 profiles/node_modules/@deepseek-ai/* 钉到 runtime（heal 之前也保持一致）
for src in "$RT"/*; do
  [[ -e "$src" ]] || continue
  name="$(basename "$src")"
  tgt="$PROF/$name"
  if [[ -L "$tgt" ]]; then
    [[ "$(readlink "$tgt")" == "$src" ]] && continue
    rm "$tgt"
  elif [[ -e "$tgt" ]]; then
    echo "  跳过 ${name}（profiles 中是真实目录，未改动）"
    continue
  fi
  ln -s "$src" "$tgt"
done

if [[ "$APP_MODE" = "packed" ]]; then
  echo "✓ pin-runtime 完成：profiles 已钉到 runtime（壳为自包含，未改动 .app）"
else
  echo "✓ pin-runtime 完成：bundle 内钉死 $pinned 个包 -> runtime"
  if [[ $backed -gt 0 ]]; then
    echo "  bundle 真实目录备份（$backed 个包）： $BAK"
  else
    echo "  （本次没有 bundle 真实目录被替换，未产生新备份）"
  fi
fi
if command -v node >/dev/null 2>&1 && [[ -f "$RT/dsh/lib/bin.js" ]]; then
  echo "  runtime 版本： $(node "$RT/dsh/lib/bin.js" --version 2>/dev/null | head -n1)"
fi

#!/usr/bin/env bash
# pin-runtime.sh — 把 DSH 的「共享安装（runtime）」权威来源钉死，让桌面壳更新盖不到它。
#
# ============================================================================
# 背景 / 问题与解法
# ----------------------------------------------------------------------------
# DSH Desktop 从某个版本起变成了一个「壳」：App 包本身不再内嵌完整的
# @deepseek-ai/dsh*，而是依赖 profile 的共享安装
#   ~/.dsh/profiles/node_modules/@deepseek-ai/*
# 来提供上游 Harness。
#
# 桌面启动时，dsh-app-boot 的 healProfilesModuleFallback() 会按 *App 包* 的依赖闭包，
# 把 profiles/node_modules/@deepseek-ai/* 重新软链接到它认为正确的来源。
# 如果未来某次壳更新把 dsh 又塞进了 App 包，heal 就会把 profile 链接打回 App 包内版本，
# 覆盖掉你精心维护的 runtime —— 所有升级/补丁前功尽弃。
#
# 解法：把 App 包内 node_modules/@deepseek-ai/*（runtime 里也存在的那些）软链接到
#   ~/.dsh/runtime/node_modules/@deepseek-ai/*
# 这样 heal 的 BFS 解析会顺着链接落到 runtime，profile 链接自然被 heal 指向 runtime。
# 结论：启动时自愈，runtime 始终权威；壳更新后重跑本脚本即可。
#
# 即使当前 App 包的 @deepseek-ai 目录是空的（壳不自带 dsh），本脚本也会补全软链接，
# 让壳自身也能解析到 runtime 的 @deepseek-ai/*。
#
# 回滚：被替换的 bundle 真实目录备份在 ~/.dsh/bundle-bak-<时间戳>/。
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
mkdir -p "$APP" "$PROF"

pinned=0
backed=0
# 1) 把 bundle 内部的 @deepseek-ai/* 钉到 runtime
#    - 已是正确软链接   -> 跳过
#    - 是真实目录       -> 备份后替换为软链接
#    - 不存在 / 错误链接 -> 直接创建 / 修正为指向 runtime 的软链接
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

echo "✓ pin-runtime 完成：bundle 内钉死 $pinned 个包 -> runtime"
if [[ $backed -gt 0 ]]; then
  echo "  bundle 真实目录备份（$backed 个包）： $BAK"
else
  echo "  （本次没有 bundle 真实目录被替换，未产生新备份）"
fi
if command -v node >/dev/null 2>&1 && [[ -f "$RT/dsh/lib/bin.js" ]]; then
  echo "  runtime 版本： $(node "$RT/dsh/lib/bin.js" --version 2>/dev/null | head -n1)"
fi

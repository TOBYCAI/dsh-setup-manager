#!/usr/bin/env bash
# app-mode.sh — 判定 DSH Desktop 壳的打包模式（被 dsh-manage.sh / pin-runtime.sh source）。
#
# 两种模式（2026-09-10 实测 Desktop 2.0.7 起为后者）：
#   shared  共享软链（≤2.0.5）：app.asar 是纯清单，unpacked 内 node_modules/@deepseek-ai/*
#           是指向 ~/.dsh/runtime 的软链农场；壳与 CLI 共用一份 runtime。
#   packed  自包含（≥2.0.7）：整棵 node_modules 打进 app.asar 正文（实测正文 ~167MB、
#           245 个 @deepseek-ai 包），unpacked 只剩 node-addon-system-* 真实目录；
#           壳自带自己的 dsh 副本，与 CLI runtime 是两份独立副本。
#
# 判定依据：asar 正文 > 1 MB（有真打包内容）且 unpacked 的 @deepseek-ai 下没有任何软链。
# 可用 DSH_APP_SELF_CONTAINED=1/0 强制覆盖（测试与特殊部署用）。
#
# 用法：
#   source "$(dirname "$0")/app-mode.sh"
#   mode="$(dsh_app_mode "$app_pkg_dir")"    # → shared | packed | unknown
#     参数必须是 .app/Contents/Resources/app.asar.unpacked/node_modules/@deepseek-ai
#     （即 pin-runtime.sh 里的 $APP）；传空或不存在的目录 → unknown。

# 内部探测：设置 _DSH_APP_MODE / _DSH_APP_MODE_WHY。
# ⚠️ 必须在**当前 shell** 调用（放进 $( ) 会让赋值留在子 shell —— 曾因此出现
#    「判定依据：」空行）。对外只暴露下面两个纯输出函数。
_dsh_app_probe() {
  local app="${1:-}"
  _DSH_APP_MODE="unknown"
  _DSH_APP_MODE_WHY=""
  case "${DSH_APP_SELF_CONTAINED:-}" in
    1) _DSH_APP_MODE="packed"; _DSH_APP_MODE_WHY="DSH_APP_SELF_CONTAINED=1（强制）"; return 0 ;;
    0) _DSH_APP_MODE="shared"; _DSH_APP_MODE_WHY="DSH_APP_SELF_CONTAINED=0（强制）"; return 0 ;;
  esac
  [ -n "$app" ] && [ -d "$app" ] || { _DSH_APP_MODE_WHY="壳内 @deepseek-ai 目录不存在"; return 0; }
  local res_dir asar size links
  res_dir="$(cd "$app/../../.." 2>/dev/null && pwd || true)"
  asar="${res_dir:-}/app.asar"
  if [ -z "${res_dir:-}" ] || [ ! -f "$asar" ]; then
    _DSH_APP_MODE_WHY="找不到 app.asar（非 macOS 布局？可用 DSH_APP_PKG 指定）"; return 0
  fi
  size="$(wc -c < "$asar" 2>/dev/null | tr -d ' ')"
  links="$(find "$app" -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${size:-0}" -gt 1048576 ] && [ "${links:-1}" -eq 0 ]; then
    _DSH_APP_MODE="packed"
    _DSH_APP_MODE_WHY="asar 正文 ${size} 字节（自带 node_modules）且无软链农场"
  else
    _DSH_APP_MODE="shared"
    _DSH_APP_MODE_WHY="asar 正文 ${size:-未知} 字节、软链 ${links:-?} 个（软链农场仍在）"
  fi
}

# 打印模式：shared | packed | unknown
dsh_app_mode() { _dsh_app_probe "$1"; printf '%s' "$_DSH_APP_MODE"; }

# 打印判定依据（给用户看的解释）
dsh_app_mode_why() { _dsh_app_probe "$1"; printf '%s' "$_DSH_APP_MODE_WHY"; }

# 默认壳内 @deepseek-ai 目录（与 pin-runtime.sh 的解析保持一致）
dsh_default_app_pkg() {
  if [ -n "${DSH_APP_PKG:-}" ]; then printf '%s' "$DSH_APP_PKG"; return 0; fi
  if [ -d "/Applications/DSH Desktop.app/Contents/Resources/app.asar.unpacked/node_modules/@deepseek-ai" ]; then
    printf '%s' "/Applications/DSH Desktop.app/Contents/Resources/app.asar.unpacked/node_modules/@deepseek-ai"
  else
    printf '%s' "${DSH_HOME:-$HOME/.dsh}/_app-shadow/node_modules/@deepseek-ai"
  fi
}

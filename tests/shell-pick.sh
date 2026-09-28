#!/usr/bin/env bash
# tests/shell-pick.sh — 「桌面壳升级渠道单选」回归测试。
#
# 背景：上游把 vX.Y.Z-next 也标记成「正式发布」（prerelease=false），于是 GitHub 的
# releases/latest 端点会返回 next 版（2026-09-28 实测 latest = v2.0.15-next，而稳定版
# 是 v2.0.15）——dsm 曾据此把 NEXT 预发布版当成「最新稳定版」，`dsm shell` 可能诱导
# 用户装预发布壳。现改为拉 release 列表、按 tag 后缀显式分渠道（无后缀=latest，
# -next=next），并改为一次单选。本测试锁定：
#   1) 渠道候选只含「基础版本严格新于当前」的渠道（同一版本跨渠道不互推、不提示降级）
#   2) 未安装（CUR 为空）时两渠道都提供
#   3) 选择解析：1/2 命中并带出各自的下载地址；0 / 空 / 非数字 / 越界 一律跳过
#   4) 非交互环境返回码 2（调用方据此只提示、不重复打印），且提示含渠道与版本
#   5) 非交互默认目标：稳定版优先，无稳定版才退回 next
# 不联网、不触碰真实 ~/.dsh（渠道变量手工注入）。
#
# 用法： bash tests/shell-pick.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export DSH_HOME="$TMP/.dsh" DSM_LIBRARY_ONLY=1
mkdir -p "$DSH_HOME/runtime"
# shellcheck disable=SC1090
source "$ROOT/bin/dsh-manage.sh"

pass=0; fail=0
ok()  { echo "  ✓ $1"; pass=$((pass+1)); }
bad() { echo "  ✗ $1"; fail=$((fail+1)); }

# 注入一组渠道版本（模拟上游：next 比 latest 多一个 -next 后缀，基础版本相同）
_DSH_SHELL_LATEST="2.0.15";      _DSH_SHELL_URL="https://example.com/DSH.Desktop-2.0.15-universal.dmg"
_DSH_SHELL_NEXT="2.0.15-next";   _DSH_SHELL_NEXT_URL="https://example.com/DSH-NEXT-2.0.15-next-universal.dmg"

echo "== 1) 渠道候选只保留严格更新的渠道 =="
_DSH_SHELL_CUR="2.0.13"
rows="$(_dsh_shell_candidates)"
n="$(printf '%s\n' "$rows" | wc -l | tr -d ' ')"
[ "$n" = "2" ] && ok "两渠道均更新时给出 2 个候选" || bad "候选数异常: $n"
printf '%s\n' "$rows" | grep -q '^next'   && ok "候选含 next 渠道"   || bad "候选缺 next: [$rows]"
printf '%s\n' "$rows" | grep -q '^latest' && ok "候选含 latest 渠道" || bad "候选缺 latest: [$rows]"

echo "== 2) 同基础版本不互推（关键回归：不把同版本的另一渠道当更新） =="
for cur in 2.0.15 2.0.15-next 2.0.15-beta.1 2.0.16; do
  _DSH_SHELL_CUR="$cur"
  rows="$(_dsh_shell_candidates)"
  [ -z "$rows" ] && ok "当前 $cur → 无候选（不提示降级/跨渠道互推）" || bad "当前 $cur 不应有候选: [$rows]"
done

echo "== 3) 未安装时两渠道都提供 =="
_DSH_SHELL_CUR=""
rows="$(_dsh_shell_candidates)"
n="$(printf '%s\n' "$rows" | wc -l | tr -d ' ')"
[ "$n" = "2" ] && ok "CUR 为空 → 两渠道均可选" || bad "未安装时候选数异常: $n"

echo "== 4) 选择解析（带出各自下载地址） =="
_DSH_SHELL_CUR="2.0.13"
rows="$(_dsh_shell_candidates)"
[ "$(_dsh_shell_pick_apply "$rows" 1)" = "$(printf '2.0.15-next\thttps://example.com/DSH-NEXT-2.0.15-next-universal.dmg')" ] \
  && ok "输入 1 → next（含 next 包地址）" || bad "输入 1 解析错误: [$(_dsh_shell_pick_apply "$rows" 1)]"
[ "$(_dsh_shell_pick_apply "$rows" 2)" = "$(printf '2.0.15\thttps://example.com/DSH.Desktop-2.0.15-universal.dmg')" ] \
  && ok "输入 2 → latest（含 stable 包地址）" || bad "输入 2 解析错误: [$(_dsh_shell_pick_apply "$rows" 2)]"
for s in "" 0 9 abc -1 " 3 "; do
  if _dsh_shell_pick_apply "$rows" "$s" >/dev/null 2>&1; then
    bad "输入 [$s] 不应命中"
  else
    ok "输入 [$s] → 跳过"
  fi
done

echo "== 5) 非交互环境只提示、返回码 2 =="
rc=0; out="$(_dsh_shell_pick </dev/null 2>&1)" || rc=$?
[ "$rc" = "2" ] && ok "非交互返回码 2（调用方据此不重复打印）" || bad "非交互返回码应为 2，实际 $rc"
printf '%s' "$out" | grep -q "非交互环境未自动升级" && ok "打印非交互提示" || bad "缺非交互提示: [$out]"
printf '%s' "$out" | grep -q "2.0.15-next" && ok "提示含 next 版本" || bad "提示缺 next 版本: [$out]"
printf '%s' "$out" | grep -q "2.0.15（latest）" && ok "提示标注渠道名" || bad "提示缺渠道标注: [$out]"

echo "== 6) 非交互默认目标：稳定版优先 =="
[ "$(_dsh_shell_default_target)" = "$(printf '2.0.15\thttps://example.com/DSH.Desktop-2.0.15-universal.dmg')" ] \
  && ok "有稳定版时默认 latest" || bad "默认目标应为 latest: [$(_dsh_shell_default_target)]"
_DSH_SHELL_LATEST=""
[ "$(_dsh_shell_default_target)" = "$(printf '2.0.15-next\thttps://example.com/DSH-NEXT-2.0.15-next-universal.dmg')" ] \
  && ok "无稳定版时退回 next" || bad "无稳定版应退回 next: [$(_dsh_shell_default_target)]"
_DSH_SHELL_LATEST="2.0.15"

echo "== 7) 渠道描述文案 =="
[ "$(_dsh_channel_desc next)" = "预发布渠道" ] && ok "next → 预发布渠道" || bad "next 描述错误"
[ "$(_dsh_channel_desc latest)" = "默认渠道" ] && ok "latest → 默认渠道" || bad "latest 描述错误"

echo
echo "shell-pick: $pass 通过 / $fail 失败"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# tests/update-pick.sh — 「runtime 升级渠道单选」回归测试。
#
# 背景：next / latest 是两个 dist-tag（渠道），不是「连续两跳」。旧实现把两者都当候选
# 逐个 y/N 确认，于是升到 next（如 0.1.7-rc.2）后还会追问 latest（如 0.1.5-rc.3）——
# 那是**降级**，且用户无法表达「我只要 next」。现改为一次单选。本测试锁定：
#   1) 候选只含「严格新于当前」的版本（永不出现 ≤ 当前的版本 → 不再有降级提示）
#   2) 同版本的两渠道合并为一行（next/latest）
#   3) 选择解析：1/2 命中；0 / 空 / 非数字 / 越界 一律视为跳过
#   4) 非交互环境不自动升级，且提示里带可用渠道与版本
# 不联网、不触碰真实 ~/.dsh。
#
# 用法： bash tests/update-pick.sh
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

echo "== 1) 候选只保留比当前更新的渠道 =="
# 当前 = latest（0.1.5-rc.3）：latest 不该作为候选（否则就是「升级到当前版本」）
_DSH_INST="0.1.5-rc.3"; _DSH_LATEST="0.1.5-rc.3"; _DSH_NEXT="0.1.7-rc.2"
rows="$(_dsh_update_candidates)"
[ "$rows" = "$(printf 'next\t0.1.7-rc.2')" ] \
  && ok "过滤掉等于当前的 latest，只剩 next" || bad "候选异常: [$rows]"

# 当前远低于两个渠道：两行候选，且都严格新于当前
_DSH_INST="0.1.2-alpha.3"
rows="$(_dsh_update_candidates)"
n="$(printf '%s\n' "$rows" | wc -l | tr -d ' ')"
[ "$n" = "2" ] && ok "两渠道均更新时给出 2 个候选" || bad "候选数异常: $n"
printf '%s\n' "$rows" | grep -q '^next' && ok "候选含 next 渠道" || bad "候选缺 next: [$rows]"
printf '%s\n' "$rows" | grep -q '^latest' && ok "候选含 latest 渠道" || bad "候选缺 latest: [$rows]"
# 关键回归：候选里绝不能出现 ≤ 当前的版本（旧 bug 就是升到 next 后又提供 latest 降级）
while IFS=$'\t' read -r _label v; do
  [ -n "$v" ] || continue
  _dsh_ver_gt "$v" "$_DSH_INST" && ok "候选 $v 严格新于当前 $_DSH_INST" || bad "候选 $v 未新于当前 $_DSH_INST"
done <<< "$rows"

echo "== 2) 同版本的两渠道合并为一行 =="
_DSH_INST="0.1.4"; _DSH_NEXT="0.1.7-rc.2"; _DSH_LATEST="0.1.7-rc.2"
rows="$(_dsh_update_candidates)"
[ "$rows" = "$(printf 'next/latest\t0.1.7-rc.2')" ] \
  && ok "合并为 next/latest 单行（同一版本不重复出现）" || bad "未合并: [$rows]"

echo "== 3) 已是最新时无候选 =="
_DSH_INST="0.1.7-rc.2"; _DSH_NEXT="0.1.7-rc.2"; _DSH_LATEST="0.1.5-rc.3"
rows="$(_dsh_update_candidates)"
[ -z "$rows" ] && ok "无更新时候选为空" || bad "应为空: [$rows]"

echo "== 4) 选择解析 =="
rows="$(printf 'next\t0.1.7-rc.2\nlatest\t0.1.5-rc.3\n')"
[ "$(_dsh_update_pick_apply "$rows" 1)" = "0.1.7-rc.2" ] && ok "输入 1 → next (0.1.7-rc.2)" || bad "输入 1 解析错误"
[ "$(_dsh_update_pick_apply "$rows" 2)" = "0.1.5-rc.3" ] && ok "输入 2 → latest (0.1.5-rc.3)" || bad "输入 2 解析错误"
for s in "" 0 9 abc -1 " 3 "; do
  if _dsh_update_pick_apply "$rows" "$s" >/dev/null 2>&1; then
    bad "输入 [$s] 不应命中"
  else
    ok "输入 [$s] → 跳过"
  fi
done

echo "== 5) 非交互环境不自动升级 =="
_DSH_INST="0.1.2-alpha.3"; _DSH_NEXT="0.1.7-rc.2"; _DSH_LATEST="0.1.5-rc.3"
rc=0; out="$(_dsh_update_pick </dev/null 2>&1)" || rc=$?
[ "$rc" != "0" ] && ok "非交互返回非 0（不执行升级）" || bad "非交互不应返回 0"
printf '%s' "$out" | grep -q "非交互环境未自动升级" && ok "打印非交互提示" || bad "缺非交互提示: [$out]"
printf '%s' "$out" | grep -q "0.1.7-rc.2" && ok "提示含可用版本" || bad "提示缺版本: [$out]"

echo
echo "update-pick: $pass 通过 / $fail 失败"
[ "$fail" -eq 0 ]

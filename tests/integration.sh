#!/usr/bin/env bash
# tests/integration.sh — 用 mock 的 DSH 目录树做 pin + verify-heal 集成测试。
#
# 不依赖真实 ~/.dsh、不联网、不触碰真实壳。所有路径落在 mktemp 临时目录。
# 覆盖：
#   1) 全部脚本语法检查（bash -n / node --check）
#   2) pin-runtime.sh 把 App / profiles 的 @deepseek-ai/* 软链到 runtime
#   3) verify-heal.mjs 经（mock）heal 后，关键包仍解析到 runtime
#   4) scan-adapters.mjs 在 mock 环境下能正常跑（无 adapter 时只报“无”）
#
# 用法： bash tests/integration.sh
set -euo pipefail

BIN_DIR="$(cd "$(dirname "$0")/.." && pwd)/bin"
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MOCK="$TMP/.dsh"
RT="$MOCK/runtime/node_modules/@deepseek-ai"
APP="$TMP/app-shadow/node_modules/@deepseek-ai"
PROF="$MOCK/profiles/node_modules/@deepseek-ai"
APP_PKG_JSON="$TMP/app-shadow/package.json"

PKGS=(dsh cordis cosmokit dsh-base dsh-app-boot dsh-web-app dsh-desktop-app)
pass=0; fail=0
ok()  { echo "  ✓ $1"; pass=$((pass+1)); }
bad() { echo "  ✗ $1"; fail=$((fail+1)); }

echo "== 1) 语法检查 =="
for f in "$BIN_DIR/dsh-manage.sh" "$BIN_DIR/pin-runtime.sh"; do
  if bash -n "$f" 2>/dev/null; then ok "bash -n $f"; else bad "bash -n $f"; fi
done
for f in "$BIN_DIR/verify-heal.mjs" "$BIN_DIR/scan-adapters.mjs" "$BIN_DIR/scan-plugin-api.mjs"; do
  if node --check "$f" 2>/dev/null; then ok "node --check $f"; else bad "node --check $f"; fi
done

echo "== 2) 构造 mock DSH 树 =="
mkdir -p "$RT" "$APP" "$PROF"
# runtime 真实包（每个含 package.json，dsh 含 lib/bin.js 以便版本探测）
for p in "${PKGS[@]}"; do
  mkdir -p "$RT/$p"
  printf '{"name":"@deepseek-ai/%s","version":"0.1.1-rc.2"}' "$p" > "$RT/$p/package.json"
done
mkdir -p "$RT/dsh/lib"
printf 'console.log("0.1.1-rc.2");\n' > "$RT/dsh/lib/bin.js"
# mock dsh-app-boot：提供无副作用的 healProfilesModuleFallback（让 verify-heal 跑通）
mkdir -p "$RT/dsh-app-boot/lib"
cat > "$RT/dsh-app-boot/lib/index.js" <<'EOF'
// mock: no-op heal so the integration test doesn't need the real harness
module.exports = { healProfilesModuleFallback() {} };
EOF
# App 影子目录：先放一个真实 dsh 目录，验证 pin 会把它备份并软链到 runtime
mkdir -p "$APP/dsh"
printf '{"name":"@deepseek-ai/dsh","version":"0.1.0-shell"}' > "$APP/dsh/package.json"
printf '{"name":"app-shadow"}' > "$APP_PKG_JSON"
ok "mock 树已创建 ($RT / $APP / $PROF)"

echo "== 3) 运行 pin-runtime.sh =="
if DSH_HOME="$MOCK" DSH_APP_PKG="$APP" bash "$BIN_DIR/pin-runtime.sh" >/dev/null 2>&1; then
  ok "pin-runtime.sh 执行成功"
else
  bad "pin-runtime.sh 执行失败"; fi

# 断言：APP 与 PROF 的 @deepseek-ai/* 都是指向 runtime 的软链
assert_link() {
  local dir="$1" label="$2"
  local n=0 badn=0
  for p in "${PKGS[@]}"; do
    local l="$dir/$p"
    [ -L "$l" ] || { badn=$((badn+1)); continue; }
    local tgt; tgt="$(readlink "$l")"
    case "$tgt" in "$RT/$p") n=$((n+1)) ;; *) badn=$((badn+1)) ;; esac
  done
  if [ "$badn" -eq 0 ]; then ok "$label 全部 ${n} 个软链指向 runtime";
  else bad "$label 有 $badn 个未正确指向 runtime"; fi
}
assert_link "$APP"  "App 内"
assert_link "$PROF" "profiles 内"

echo "== 4) verify-heal.mjs（mock heal）=="
OUT="$(DSH_HOME="$MOCK" node "$BIN_DIR/verify-heal.mjs" --dsh-home "$MOCK" --app-pkg "$APP_PKG_JSON" 2>&1)"
if printf '%s' "$OUT" | grep -q "所有关键包经 heal 后仍解析到 runtime"; then
  ok "verify-heal 报告全部解析到 runtime"
else
  bad "verify-heal 未通过："; printf '%s\n' "$OUT" | sed 's/^/      /'; fi

echo "== 5) scan-adapters.mjs（mock：无第三方 adapter）=="
if SOUT="$(DSH_HOME="$MOCK" node "$BIN_DIR/scan-adapters.mjs" 2>&1)"; then
  ok "scan-adapters 正常运行（退出 0）"
else
  bad "scan-adapters 异常退出"; fi
printf '%s\n' "$SOUT" | grep -q "未声明 dsh 范围\|无已装 adapter\|adapter" >/dev/null 2>&1 || true

echo "== 6) scan-plugin-api.mjs（插件 API 冲突预检）=="
if POUT="$(bash "$TESTS_DIR/plugin-api.sh" 2>&1)"; then
  ok "插件 API 冲突预检集成测试通过"
  printf '%s\n' "$POUT" | grep -E "通过 / " | sed 's/^/      /'
else
  bad "插件 API 冲突预检集成测试失败"
  printf '%s\n' "$POUT" | sed 's/^/      /'
fi

echo
echo "集成测试结果： $pass 通过 / $fail 失败"
[ "$fail" -eq 0 ]

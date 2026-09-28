#!/usr/bin/env bash
# tests/integration.sh — 用 mock 的 DSH 目录树做 pin + verify-heal 集成测试。
#
# 不依赖真实 ~/.dsh、不联网、不触碰真实壳。所有路径落在 mktemp 临时目录。
# 覆盖：
#   1) 全部脚本语法检查（bash -n / node --check）
#   2) pin-runtime.sh 把 App / profiles 的 @deepseek-ai/* 软链到 runtime
#   3) verify-heal.mjs：旧版 dsh 经（mock）heal 后关键包仍解析到 runtime；
#      dsh ≥0.1.7-alpha.1（无 healProfilesModuleFallback 导出）时降级为静态校验且不抛异常
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
for f in "$BIN_DIR/dsh-manage.sh" "$BIN_DIR/pin-runtime.sh" "$BIN_DIR/app-mode.sh"; do
  if bash -n "$f" 2>/dev/null; then ok "bash -n $f"; else bad "bash -n $f"; fi
done
for f in "$BIN_DIR/verify-heal.mjs" "$BIN_DIR/scan-adapters.mjs" "$BIN_DIR/scan-plugin-api.mjs" "$BIN_DIR/check-native-addons.mjs" "$BIN_DIR/check-desktop.mjs"; do
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
if printf '%s' "$OUT" | grep -qE "所有关键包.*仍解析到 runtime"; then
  ok "verify-heal 报告全部解析到 runtime"
else
  bad "verify-heal 未通过："; printf '%s\n' "$OUT" | sed 's/^/      /'; fi
if printf '%s' "$OUT" | grep -q "模拟启动自愈"; then
  ok "verify-heal 在 heal API 存在时走 heal 模拟路径"
else
  bad "verify-heal 未走 heal 模拟路径：$(printf '%s' "$OUT" | grep '校验模式' || echo '(无校验模式行)')"; fi

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

echo "== 7) native addon 缺失/白名单回归测试 =="
if NOUT="$(bash "$TESTS_DIR/native-addons.sh" 2>&1)"; then
  ok "native addon 回归测试通过"
else
  bad "native addon 回归测试失败"; printf '%s\n' "$NOUT" | sed 's/^/      /'
fi

echo "== 8) runtime 安装事务与中断回滚 =="
if TOUT="$(bash "$TESTS_DIR/runtime-transaction.sh" 2>&1)"; then
  ok "runtime 事务回归测试通过"
else
  bad "runtime 事务回归测试失败"; printf '%s\n' "$TOUT" | sed 's/^/      /'
fi

echo "== 9) pin-runtime.sh：自包含壳（≥2.0.7）必须跳过改造 .app，仅钉 profiles =="
# 构造自包含壳：app.asar 正文 > 1MB（大小阈值）且 unpacked 下无软链农场
SC="$TMP/selfcontained"; SCRT="$SC/.dsh/runtime/node_modules/@deepseek-ai"; SCAPP="$SC/app/node_modules/@deepseek-ai"
SCH="$SC/.dsh"; SCPROF="$SCH/profiles/node_modules/@deepseek-ai"
mkdir -p "$SCRT" "$SCAPP" "$SCPROF" "$SC/app"
for p in "${PKGS[@]}"; do
  mkdir -p "$SCRT/$p" "$SCAPP/$p"
  printf '{"name":"@deepseek-ai/%s","version":"0.1.5-rc.1"}' "$p" > "$SCRT/$p/package.json"
  printf '{"name":"@deepseek-ai/%s","version":"0.1.5-rc.1"}' "$p" > "$SCAPP/$p/package.json"
done
# 1.1MB 的假 asar（只验判定阈值；内容不参与判定）。
# 路径层级对齐真实 .app：app-mode.sh 从 <scope>/../../.. 找 app.asar，即
# <scope>=.../node_modules/@deepseek-ai 时 asar 在 .../app.asar（此处 = $SC/app.asar）。
node -e 'require("fs").writeFileSync(process.argv[1], Buffer.alloc(1100000))' "$SC/app.asar"
# assert_link 用全局 $RT 作比对基准，这里切到本场景的 runtime
RT="$SCRT"
SOUT="$(DSH_HOME="$SCH" DSH_APP_PKG="$SCAPP" bash "$BIN_DIR/pin-runtime.sh" 2>&1)" && SRC=0 || SRC=$?
[ "$SRC" = "0" ] && ok "pin-runtime.sh 执行成功" || bad "pin-runtime.sh 失败（退出 $SRC）"
printf '%s' "$SOUT" | grep -q "自包含" && ok "识别自包含并声明跳过 .app" || bad "未识别自包含：$SOUT"
sc_n=0; sc_bad=0
for p in "${PKGS[@]}"; do
  if [ -L "$SCAPP/$p" ]; then sc_bad=$((sc_bad+1)); else sc_n=$((sc_n+1)); fi
done
[ "$sc_bad" -eq 0 ] && ok "未改动壳内目录（${sc_n} 个真实目录保持原样）" || bad "自包含模式仍改写了壳内 $sc_bad 个条目"
assert_link "$SCPROF" "自包含壳的 profiles"
# 反例：显式声明为共享软链（DSH_APP_SELF_CONTAINED=0）时应照旧改写 .app
SOUT2="$(DSH_HOME="$SCH" DSH_APP_PKG="$SCAPP" DSH_APP_SELF_CONTAINED=0 bash "$BIN_DIR/pin-runtime.sh" 2>&1)" || true
assert_link "$SCAPP" "强制 shared 时的 App 内"

echo "== 10) runtime 升级渠道单选（next / latest 二选一）=="
if UOUT="$(bash "$TESTS_DIR/update-pick.sh" 2>&1)"; then
  ok "升级渠道单选回归测试通过"
  printf '%s\n' "$UOUT" | grep -E "通过 / " | sed 's/^/      /'
else
  bad "升级渠道单选回归测试失败"; printf '%s\n' "$UOUT" | sed 's/^/      /'
fi

echo "== 11) 桌面壳升级渠道单选（latest / next，按 tag 后缀分渠道）=="
if SOUT="$(bash "$TESTS_DIR/shell-pick.sh" 2>&1)"; then
  ok "壳升级渠道单选回归测试通过"
  printf '%s\n' "$SOUT" | grep -E "通过 / " | sed 's/^/      /'
else
  bad "壳升级渠道单选回归测试失败"; printf '%s\n' "$SOUT" | sed 's/^/      /'
fi

echo "== 12) verify-heal.mjs：dsh ≥0.1.7 无 heal API 时降级为静态校验（不得抛异常）=="
# 注意：9) 把全局 $RT 切到了自包含场景，这里显式用回主 mock 的 runtime
MOCKRT="$MOCK/runtime/node_modules/@deepseek-ai"
# 覆盖 mock 的 dsh-app-boot：0.1.7-alpha.1 起不再导出 healProfilesModuleFallback
cat > "$MOCKRT/dsh-app-boot/lib/index.js" <<'EOF'
// mock: dsh 0.1.7-alpha.1+ 形态 —— healProfilesModuleFallback 已被上游删除
module.exports = {};
EOF
if OUT2="$(DSH_HOME="$MOCK" node "$BIN_DIR/verify-heal.mjs" --dsh-home "$MOCK" --app-pkg "$APP_PKG_JSON" 2>&1)"; then
  ok "verify-heal 在缺失 heal API 时正常退出（未抛 TypeError）"
  if printf '%s' "$OUT2" | grep -q "静态软链校验"; then
    ok "verify-heal 明确标注降级为静态校验"
  else
    bad "verify-heal 未标注静态校验模式"; fi
  if printf '%s' "$OUT2" | grep -qE "所有关键包.*仍解析到 runtime"; then
    ok "verify-heal 静态校验结论正确（仍解析到 runtime）"
  else
    bad "verify-heal 静态校验结论异常：$(printf '%s' "$OUT2" | tail -1)"; fi
else
  bad "verify-heal 在缺失 heal API 时退出非 0："; printf '%s\n' "$OUT2" | sed 's/^/      /'
fi

# 反向用例：profiles 未初始化 → 明确提示跳过，而不是静默报「全部 OK」
MOCK2="$TMP/.dsh-noprof"
mkdir -p "$MOCK2/runtime"
cp -R "$MOCK/runtime/node_modules" "$MOCK2/runtime/node_modules"
if OUT3="$(DSH_HOME="$MOCK2" node "$BIN_DIR/verify-heal.mjs" --dsh-home "$MOCK2" 2>&1)"; then
  if printf '%s' "$OUT3" | grep -q "未初始化"; then
    ok "profiles 未初始化时明确提示跳过（不误报 OK）"
  else
    bad "profiles 未初始化时未提示：$(printf '%s' "$OUT3" | tail -1)"; fi
else
  bad "profiles 未初始化时应按「无可校验」退出 0，实际非 0："; printf '%s\n' "$OUT3" | sed 's/^/      /'
fi

echo
echo "集成测试结果： $pass 通过 / $fail 失败"
[ "$fail" -eq 0 ]

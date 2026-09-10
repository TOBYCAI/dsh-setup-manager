#!/usr/bin/env bash
# tests/desktop-check.sh — check-desktop.mjs 的 mock 集成测试。
#
# 不依赖真实 /Applications、真实 ~/.dsh。asar 用 node 构造最小合法头
# （pickle 布局：u32@0=4、u32@12=JSON 长度、JSON@16）。
# 覆盖：
#   1) 应用代码 import 的命名导出被 runtime 移除 → 退出 1（致命冲突，即
#      settingsNamespace 类故障的回归）
#   2) 全部兼容（含清单与 runtime 包集合一致）→ 退出 0
#   3) 清单缺口：runtime 有而 asar 清单没有 → 警告但不致命（未被 import 时退出 0）
#   4) 未安装 Desktop（--app 指向不存在路径）→ 退出 2（跳过而非失败）
#   5) asar 损坏 → 退出 2（跳过，不误报冲突）
#   6) --quiet：有致命冲突时才输出；无冲突时静默
#   7) Info.plist 版本号提取（xml plist）
#
# 用法： bash tests/desktop-check.sh
set -euo pipefail

BIN_DIR="$(cd "$(dirname "$0")/.." && pwd)/bin"
SCRIPT="$BIN_DIR/check-desktop.mjs"
pass=0; fail=0
ok()  { echo "  ✓ $1"; pass=$((pass+1)); }
bad() { echo "  ✗ $1"; fail=$((fail+1)); }

OUT=""; RC=""
run_check() {
  OUT="$(node "$SCRIPT" "$@" 2>&1)" && RC=0 || RC=$?
}

# ---------- mock 构造器 ----------
# 最小合法 asar：header 清单只含 node_modules/@deepseek-ai/<pkgs...>
mk_asar() {
  local path="$1"; shift
  node -e '
    const fs = require("fs");
    const [path, pkgsJson] = process.argv.slice(1);
    const pkgs = JSON.parse(pkgsJson);
    const scope = {};
    for (const p of pkgs) scope[p] = { files: { "package.json": { size: 10 } } };
    const manifest = { files: { node_modules: { files: { "@deepseek-ai": { files: scope } } } } };
    const payload = Buffer.from(JSON.stringify(manifest), "utf8");
    const head = Buffer.alloc(16);
    head.writeUInt32LE(4, 0);
    head.writeUInt32LE(payload.length + 8, 4);
    head.writeUInt32LE(payload.length + 4, 8);
    head.writeUInt32LE(payload.length, 12);
    fs.writeFileSync(path, Buffer.concat([head, payload]));
  ' "$path" "$(printf '%s\n' "$@" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().split()))')"
}

# runtime：dsh-settings 导出可配置
mk_runtime() {
  local rt="$1"; shift
  mkdir -p "$rt/@deepseek-ai/dsh-settings/lib"
  printf '%s' '{"name":"@deepseek-ai/dsh-settings","version":"0.1.2-rc.1","main":"./lib/index.js"}' \
    > "$rt/@deepseek-ai/dsh-settings/package.json"
  { printf '%s\n' "export { SettingsConflictError, SettingsProvider };"
    for s in "$@"; do printf 'export const %s = 1;\n' "$s"; done
  } > "$rt/@deepseek-ai/dsh-settings/lib/index.js"
}

# Desktop 应用骨架：Info.plist（可选版本号）+ asar + unpacked/lib 应用代码
mk_app() {
  local app="$1" ver="$2"; shift 2
  local res="$app/Contents/Resources"
  mkdir -p "$res/app.asar.unpacked/lib"
  if [ -n "$ver" ]; then
    printf '<?xml version="1.0"?><plist><dict><key>CFBundleShortVersionString</key><string>%s</string></dict></plist>' "$ver" \
      > "$app/Contents/Info.plist"
  fi
  mk_asar "$res/app.asar" "$@"
  for f in "$@"; do :; done
}

mk_appcode() {
  local unpacked="$1" code="$2"
  printf '%s\n' "$code" > "$unpacked/lib/app.js"
}

# 真打包 asar（模式 B，Desktop ≥2.0.7）：清单 + 正文（文件按 offset 落在 dataOffset 之后）。
# $2 = {"相对路径": "文件内容"} 的 JSON。
mk_asar_packed() {
  local path="$1" files="$2"
  node -e '
    const fs = require("fs");
    const [path, filesJson] = process.argv.slice(1);
    const files = JSON.parse(filesJson);
    const root = { files: {} };
    const put = (parts, entry) => {
      let node = root;
      for (let i = 0; i < parts.length - 1; i++) {
        if (!node.files[parts[i]]) node.files[parts[i]] = { files: {} };
        node = node.files[parts[i]];
      }
      node.files[parts[parts.length - 1]] = entry;
    };
    let offset = 0;
    const chunks = [];
    for (const rel of Object.keys(files)) {
      const buf = Buffer.from(files[rel], "utf8");
      put(rel.split("/"), { size: buf.length, offset: String(offset) });
      chunks.push(buf);
      offset += buf.length;
    }
    const payload = Buffer.from(JSON.stringify(root), "utf8");
    const padded = (payload.length + 3) & ~3;
    const dataOffset = 16 + padded;
    const head = Buffer.alloc(dataOffset);
    head.writeUInt32LE(4, 0);
    head.writeUInt32LE(padded + 8, 4);
    head.writeUInt32LE(padded + 4, 8);
    head.writeUInt32LE(payload.length, 12);
    payload.copy(head, 16);
    fs.writeFileSync(path, Buffer.concat([head, ...chunks]));
  ' "$path" "$files"
}

mk_app_packed() {
  local app="$1" ver="$2" files="$3"
  local res="$app/Contents/Resources"
  mkdir -p "$res"
  if [ -n "$ver" ]; then
    printf '<?xml version="1.0"?><plist><dict><key>CFBundleShortVersionString</key><string>%s</string></dict></plist>' "$ver" \
      > "$app/Contents/Info.plist"
  fi
  mk_asar_packed "$res/app.asar" "$files"
}

# 自包含壳的 asar 内容：应用代码 + 壳自带 dsh 版本
packed_files() {
  local bundled="$1" appcode="$2"
  node -e '
    const [bundled, appcode] = process.argv.slice(1);
    process.stdout.write(JSON.stringify({
      "package.json": JSON.stringify({ name: "dsh-desktop", version: "2.0.7" }),
      "lib/app.js": appcode,
      "node_modules/@deepseek-ai/dsh/package.json": JSON.stringify({ name: "@deepseek-ai/dsh", version: bundled }),
    }));
  ' "$bundled" "$appcode"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== 场景 1) 命名导出被 runtime 移除 → 退出 1（settingsNamespace 类故障回归）=="
H="$TMP/s1"; RT="$H/runtime/node_modules"; APP="$TMP/s1/DSH Desktop.app"
mk_runtime "$RT"
mk_app "$APP" "2.0.4" dsh-settings
mk_appcode "$APP/Contents/Resources/app.asar.unpacked" \
  "import { settingsNamespace } from '@deepseek-ai/dsh-settings';"
run_check --app "$APP" --dsh-home "$H"
[ "$RC" = "1" ] && ok "退出码 1（致命冲突）" || bad "退出码应为 1，实际 $RC"
printf '%s' "$OUT" | grep -q "settingsNamespace" && ok "指出缺失符号 settingsNamespace" || bad "未指出缺失符号"
printf '%s' "$OUT" | grep -q "致命冲突" && ok "标注为致命冲突" || bad "未标注致命冲突"
printf '%s' "$OUT" | grep -q "v2.0.4" && ok "提取了 Info.plist 版本号" || bad "未提取版本号"

echo "== 场景 2) 全部兼容 → 退出 0 =="
H="$TMP/s2"; RT="$H/runtime/node_modules"; APP="$TMP/s2/DSH Desktop.app"
mk_runtime "$RT"
mk_app "$APP" "" dsh-settings
mk_appcode "$APP/Contents/Resources/app.asar.unpacked" \
  "import { SettingsProvider } from '@deepseek-ai/dsh-settings';"
run_check --app "$APP" --dsh-home "$H"
[ "$RC" = "0" ] && ok "退出码 0" || bad "退出码应为 0，实际 $RC"
printf '%s' "$OUT" | grep -q "主进程可加载" && ok "报告主进程可加载" || bad "未报告主进程可加载"

echo "== 场景 3) 清单缺口（runtime 有而 asar 没有）→ 警告但不致命 =="
H="$TMP/s3"; RT="$H/runtime/node_modules"; APP="$TMP/s3/DSH Desktop.app"
mk_runtime "$RT"
mkdir -p "$RT/@deepseek-ai/dsh-extra/lib"
printf '%s' '{"name":"@deepseek-ai/dsh-extra","version":"1.0.0","main":"./lib/index.js"}' \
  > "$RT/@deepseek-ai/dsh-extra/package.json"
printf '%s\n' 'export const x = 1;' > "$RT/@deepseek-ai/dsh-extra/lib/index.js"
mk_app "$APP" "" dsh-settings   # 清单里没有 dsh-extra
mk_appcode "$APP/Contents/Resources/app.asar.unpacked" \
  "import { SettingsProvider } from '@deepseek-ai/dsh-settings';"
run_check --app "$APP" --dsh-home "$H"
[ "$RC" = "0" ] && ok "未被 import 的缺口不致命（退出 0）" || bad "退出码应为 0，实际 $RC"
printf '%s' "$OUT" | grep -q "dsh-extra" && ok "警告里列出了缺口包 dsh-extra" || bad "未列出缺口包"

echo "== 场景 4) 未安装 Desktop → 退出 2（跳过）=="
H="$TMP/s4"; RT="$H/runtime/node_modules"
mk_runtime "$RT"
run_check --app "$TMP/s4/no-such-app" --dsh-home "$H"
[ "$RC" = "2" ] && ok "退出码 2（跳过而非失败）" || bad "退出码应为 2，实际 $RC"
printf '%s' "$OUT" | grep -q "跳过" && ok "输出跳过说明" || bad "未输出跳过说明"

echo "== 场景 5) asar 损坏 → 退出 2（不误报冲突）=="
H="$TMP/s5"; RT="$H/runtime/node_modules"; APP="$TMP/s5/DSH Desktop.app"
mk_runtime "$RT"
mkdir -p "$APP/Contents/Resources/app.asar.unpacked/lib"
printf 'not an asar at all, just garbage bytes ......' > "$APP/Contents/Resources/app.asar"
run_check --app "$APP" --dsh-home "$H"
[ "$RC" = "2" ] && ok "退出码 2（解析失败按跳过处理）" || bad "退出码应为 2，实际 $RC"
printf '%s' "$OUT" | grep -qE "跳过|不符" && ok "说明了解析失败原因" || bad "未说明解析失败"

echo "== 场景 6) --quiet：致命冲突才输出 =="
H="$TMP/s6"; RT="$H/runtime/node_modules"; APP="$TMP/s6/DSH Desktop.app"
mk_runtime "$RT"
mk_app "$APP" "" dsh-settings
mk_appcode "$APP/Contents/Resources/app.asar.unpacked" \
  "import { SettingsProvider } from '@deepseek-ai/dsh-settings';"
run_check --app "$APP" --dsh-home "$H" --quiet
[ "$RC" = "0" ] && ok "无冲突时退出 0" || bad "退出码应为 0，实际 $RC"
[ -z "$OUT" ] && ok "无冲突时静默（无输出）" || bad "静默模式不应有输出：$OUT"

echo "== 场景 7) 真打包 asar（Desktop ≥2.0.7 自包含）→ 不跳过、应用代码从 asar 正文读出 =="
H="$TMP/s7"; RT="$H/runtime/node_modules"; APP="$TMP/s7/DSH Desktop.app"
mk_runtime "$RT"
mkdir -p "$RT/@deepseek-ai/dsh/lib"
printf '%s' '{"name":"@deepseek-ai/dsh","version":"0.1.2-rc.1","main":"./lib/index.js"}' \
  > "$RT/@deepseek-ai/dsh/package.json"
printf '%s\n' 'export const x = 1;' > "$RT/@deepseek-ai/dsh/lib/index.js"
mk_app_packed "$APP" "2.0.7" "$(packed_files 9.9.9 'import { SettingsProvider } from "@deepseek-ai/dsh-settings";')"
run_check --app "$APP" --dsh-home "$H"
[ "$RC" = "0" ] && ok "退出码 0（未按「环境不满足」跳过）" || bad "退出码应为 0，实际 $RC"
printf '%s' "$OUT" | grep -q "自包含" && ok "识别为自包含打包" || bad "未识别自包含"
printf '%s' "$OUT" | grep -q "壳自带 dsh 副本 9.9.9" && ok "读出壳自带 dsh 版本（asar 正文内）" || bad "未读出壳自带版本：$OUT"
printf '%s' "$OUT" | grep -q "版本偏差" && ok "报出版本偏差（9.9.9 ≠ 0.1.2-rc.1）" || bad "未报版本偏差"
printf '%s' "$OUT" | grep -q "@deepseek-ai/dsh-settings: ✅ 可解析" && ok "应用代码从 asar 正文读出并比对（扫到 import）" || bad "未扫到 asar 内应用代码"
printf '%s' "$OUT" | grep -q "扫描文件 1 个" && ok "扫描文件数正确（仅 lib/app.js）" || bad "扫描文件数不对：$OUT"

echo "== 场景 8) 自包含 + 版本一致 + 缺导出 → 退出 1（同源比对，确属致命）=="
H="$TMP/s8"; RT="$H/runtime/node_modules"; APP="$TMP/s8/DSH Desktop.app"
mk_runtime "$RT"
mkdir -p "$RT/@deepseek-ai/dsh/lib"
printf '%s' '{"name":"@deepseek-ai/dsh","version":"0.1.2-rc.1","main":"./lib/index.js"}' \
  > "$RT/@deepseek-ai/dsh/package.json"
printf '%s\n' 'export const x = 1;' > "$RT/@deepseek-ai/dsh/lib/index.js"
mk_app_packed "$APP" "2.0.7" "$(packed_files 0.1.2-rc.1 'import { settingsNamespace } from "@deepseek-ai/dsh-settings";')"
run_check --app "$APP" --dsh-home "$H"
[ "$RC" = "1" ] && ok "退出码 1（版本一致 → 基准等价 → 缺符号必崩）" || bad "退出码应为 1，实际 $RC"
printf '%s' "$OUT" | grep -q "致命冲突" && ok "标注为致命冲突" || bad "未标注致命冲突"
printf '%s' "$OUT" | grep -q "settingsNamespace" && ok "指出缺失符号" || bad "未指出缺失符号"

echo "== 场景 9) 自包含 + 版本不同 + 缺导出 → 仅供参考（退出 0，不误杀）=="
H="$TMP/s9"; RT="$H/runtime/node_modules"; APP="$TMP/s9/DSH Desktop.app"
mk_runtime "$RT"
mkdir -p "$RT/@deepseek-ai/dsh/lib"
printf '%s' '{"name":"@deepseek-ai/dsh","version":"0.1.2-rc.1","main":"./lib/index.js"}' \
  > "$RT/@deepseek-ai/dsh/package.json"
printf '%s\n' 'export const x = 1;' > "$RT/@deepseek-ai/dsh/lib/index.js"
mk_app_packed "$APP" "2.0.7" "$(packed_files 9.9.9 'import { settingsNamespace } from "@deepseek-ai/dsh-settings";')"
run_check --app "$APP" --dsh-home "$H"
[ "$RC" = "0" ] && ok "退出码 0（两端版本不同，差异仅供参考）" || bad "退出码应为 0，实际 $RC"
printf '%s' "$OUT" | grep -q "仅供参考" && ok "输出标注为参考而非致命" || bad "未标注仅供参考：$OUT"
printf '%s' "$OUT" | grep -q "settingsNamespace" && ok "仍列出差异项" || bad "未列出差异项"

echo
echo "Desktop 兼容性检查测试结果： $pass 通过 / $fail 失败"
[ "$fail" -eq 0 ]

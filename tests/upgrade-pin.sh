#!/usr/bin/env bash
# issue：npm 渠道就地升级恒失败（rc.1→rc.2 实测复现）。
# 根因：_dsh_do_upgrade 只删 lockfile 重装，从不把目标版本写进 package.json——
# runtime 已精确 pin 旧版本时，pnpm install 解析出的仍是旧版，版本核对失败回滚。
# 本文件回归 _dsh_pin_runtime_version 的四个行为：写入 / 幂等 / 事务回滚 / 缺文件拒绝。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export DSH_HOME="$TMP/.dsh" DSM_LIBRARY_ONLY=1
mkdir -p "$DSH_HOME/runtime/node_modules"
printf '{"name":"runtime","dependencies":{"@deepseek-ai/dsh":"0.1.5-rc.1"}}\n' > "$DSH_HOME/runtime/package.json"
# shellcheck disable=SC1090
source "$ROOT/bin/dsh-manage.sh"

# 1) 旧版本 pin → 写入目标版本
_dsh_pin_runtime_version "$DSH_HOME/runtime" "0.1.5-rc.2" >/dev/null
node -e 'const j=require(process.argv[1]);if(j.dependencies["@deepseek-ai/dsh"]!=="0.1.5-rc.2")process.exit(1)' "$DSH_HOME/runtime/package.json"

# 2) 已是目标版本 → 幂等：文件零改动
cp "$DSH_HOME/runtime/package.json" "$TMP/before.json"
_dsh_pin_runtime_version "$DSH_HOME/runtime" "0.1.5-rc.2" >/dev/null
cmp -s "$TMP/before.json" "$DSH_HOME/runtime/package.json"

# 3) 事务语义：注入后回滚必须还原旧 pin
_dsh_tx_begin "$DSH_HOME/runtime"
_dsh_pin_runtime_version "$DSH_HOME/runtime" "0.2.0" >/dev/null
grep -q '"0.2.0"' "$DSH_HOME/runtime/package.json"
_dsh_tx_rollback "$DSH_HOME/runtime" >/dev/null
node -e 'const j=require(process.argv[1]);if(j.dependencies["@deepseek-ai/dsh"]!=="0.1.5-rc.2")process.exit(1)' "$DSH_HOME/runtime/package.json"

# 4) package.json 缺失 → 拒绝（调用方 _dsh_do_upgrade 会走回滚）
rm "$DSH_HOME/runtime/package.json"
if _dsh_pin_runtime_version "$DSH_HOME/runtime" "0.2.0" 2>/dev/null; then
  echo "✗ 缺 package.json 时应当失败" >&2; exit 1
fi

echo "upgrade pin: 写入 / 幂等 / 事务回滚 / 缺文件拒绝 全部通过"

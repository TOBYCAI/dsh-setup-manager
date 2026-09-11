#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export DSH_HOME="$TMP/.dsh" DSM_LIBRARY_ONLY=1
mkdir -p "$DSH_HOME/runtime/node_modules"
printf 'old\n' > "$DSH_HOME/runtime/node_modules/state"
printf '{"old":true}\n' > "$DSH_HOME/runtime/package.json"
# shellcheck disable=SC1090
source "$ROOT/bin/dsh-manage.sh"

_dsh_tx_begin "$DSH_HOME/runtime"
printf 'new\n' > "$DSH_HOME/runtime/package.json"
mkdir -p "$DSH_HOME/runtime/node_modules"; printf 'partial\n' > "$DSH_HOME/runtime/node_modules/state"
printf 'generated\n' > "$DSH_HOME/runtime/pnpm-workspace.yaml"
_dsh_tx_rollback "$DSH_HOME/runtime"
grep -q old "$DSH_HOME/runtime/package.json"
grep -q old "$DSH_HOME/runtime/node_modules/state"
[ ! -e "$DSH_HOME/runtime/pnpm-workspace.yaml" ]

_dsh_tx_begin "$DSH_HOME/runtime"
mkdir -p "$DSH_HOME/runtime/node_modules"; printf 'new\n' > "$DSH_HOME/runtime/node_modules/state"
_dsh_tx_commit
grep -q new "$DSH_HOME/runtime/node_modules/state"

printf 'old-again\n' > "$DSH_HOME/runtime/node_modules/state"
( _dsh_tx_begin "$DSH_HOME/runtime"; mkdir -p "$DSH_HOME/runtime/node_modules"; printf 'partial\n' > "$DSH_HOME/runtime/node_modules/state"; exit 7 ) >/dev/null 2>&1 || true
grep -q old-again "$DSH_HOME/runtime/node_modules/state"

# 模拟 SIGKILL（没有机会执行 EXIT trap）：下一次 dsm 调用应发现残留并恢复。
printf 'before-kill\n' > "$DSH_HOME/runtime/node_modules/state"
( _dsh_tx_begin "$DSH_HOME/runtime"; trap - EXIT INT TERM HUP; mkdir -p "$DSH_HOME/runtime/node_modules"; printf 'partial\n' > "$DSH_HOME/runtime/node_modules/state"; exit 137 ) >/dev/null 2>&1 || true
_dsh_recover_orphan_tx >/dev/null
grep -q before-kill "$DSH_HOME/runtime/node_modules/state"

# 残留事务 + 当前 runtime 仍健康 ⇒ 绝不自动回滚（2026-09-11 实测：rc.2 升级
# 成功后其结果被下一条 dsm 命令的孤儿事务恢复降级回 rc.1）。场景对齐「已提交
# 但清理失败」：事务目录里是旧 node_modules，runtime 里已有完整的新版本。
( _dsh_tx_begin "$DSH_HOME/runtime"; trap - EXIT INT TERM HUP; mkdir -p "$DSH_HOME/runtime/node_modules"; printf 'stale-tx\n' > "$DSH_HOME/runtime/node_modules/state"; exit 137 ) >/dev/null 2>&1 || true
# 崩溃后新版本已装好（pnpm install 完成、commit 的 rm -rf 失败留下的现场）
mkdir -p "$DSH_HOME/runtime/node_modules/@deepseek-ai/dsh"
printf '{"name":"dsh","version":"0.2.0"}\n' > "$DSH_HOME/runtime/node_modules/@deepseek-ai/dsh/package.json"
printf '{"name":"runtime","dependencies":{"@deepseek-ai/dsh":"0.2.0"}}\n' > "$DSH_HOME/runtime/package.json"
printf 'healthy-new\n' > "$DSH_HOME/runtime/node_modules/state"
out="$(_dsh_recover_orphan_tx)"
printf '%s\n' "$out" | grep -q "不自动回滚"
grep -q healthy-new "$DSH_HOME/runtime/node_modules/state"
# 恢复决策必须保留事务目录（等用户自行决定 rollback 或清理）
find "$DSH_HOME" -maxdepth 1 -type d -name '.dsm-runtime-tx.*' | grep -q . && rm -rf "$DSH_HOME"/.dsm-runtime-tx.*

echo "runtime transaction: rollback / commit / interrupted-exit / orphan recovery / healthy-no-rollback 全部通过"

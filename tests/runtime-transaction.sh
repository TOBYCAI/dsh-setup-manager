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
echo "runtime transaction: rollback / commit / interrupted-exit / orphan recovery 全部通过"

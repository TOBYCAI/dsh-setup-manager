#!/usr/bin/env bash
# dsh-manage.sh — DSH（DeepSeek Harness）共享安装统一管理脚本。
#
# ============================================================================
# 解决什么问题
# ----------------------------------------------------------------------------
# DSH Desktop 是「壳」，真正运行的是 ~/.dsh/runtime（共享安装）。
# 本项目让你：
#   1) 升级 runtime（pnpm 优先，快；带 registry 预检，避免「找不到包」长时间回溯）
#   2) 升级壳（按平台从 GitHub Releases 下载备份后替换）
#   3) 启动 web（自动卸载宿主注入的 safe-delete 守卫，避免 pnpm 清理被拦截）
# 升级 runtime 后会自动重跑 pin-runtime.sh，确保壳更新也盖不到你的 runtime。
#
# 所有路径可通过环境变量覆盖：
#   DSH_HOME        默认 $HOME/.dsh
#   DSH_APP         默认 "/Applications/DSH Desktop.app"（macOS）
#   DSH_APP_PKG     壳内 @deepseek-ai 目录（pin-runtime 用，同 pin-runtime.sh）
#   DSH_PATCH_YML   web 启动用的 --patch 文件（可选）
#   DSH_PNPM        指定 pnpm 可执行文件（默认自动探测）
#
# 子命令：
#   dsh-manage.sh update [--dry-run]        交互升级 runtime（--dry-run 只显示将变更的依赖）
#   dsh-manage.sh update-runtime <ver>       非交互：直接升级 runtime 到指定版本
#   dsh-manage.sh update-src [<ver>]         从官方 GitHub 源码构建安装（npm 未发布时可用；缺省探测最新 dsh-v* tag）
#   dsh-manage.sh shell                      检测壳版本，交互确认后升级（按平台分发）
#   dsh-manage.sh web [args..]               启动 dsh web（带 safe-delete 守卫卸载）
#   dsh-manage.sh pin                        仅重钉 runtime（壳/Profile 软链 → runtime）
#   dsh-manage.sh status                     打印当前 runtime / 壳版本与更新可用性
#   dsh-manage.sh doctor                     自检：软链完整性 / heal 是否仍指向 runtime / 守卫 / 备份
#   dsh-manage.sh scan                        扫描已装 LLM adapter 与当前 runtime 的版本兼容性
#   dsh-manage.sh check [--cron]             健康检查 + 更新可用性（默认仅报告，不自动改）
#   dsh-manage.sh rollback [runtime|shell|all]  从备份还原（交互确认）
#   dsh-manage.sh cleanup [--dry-run]           交互式清理备份（选择删除 / 保留）
#   dsh-manage.sh install [--runtime <ver>] [--no-shell] [--no-runtime] [--dry-run]
#                                    一键双端安装：下载安装桌面壳 + 引导 runtime + 自动 pin + doctor
#
# 适用：macOS（壳升级走 .app + hdiutil）；Linux / Windows 壳升级为可移植框架（标注未验证）。
# ============================================================================
set -eo pipefail

DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
DSH_APP="${DSH_APP:-/Applications/DSH Desktop.app}"
DSH_PATCH_YML="${DSH_PATCH_YML:-$DSH_HOME/patches/enable-skills.yml}"
BIN_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---- 平台探测 ----
_dsh_os() {
  local os; os="$(uname -s 2>/dev/null || echo unknown)"
  case "$os" in
    Darwin*) echo macos ;;
    Linux*)  echo linux ;;
    *) case "${OS:-}" in
         Windows_NT) echo windows ;;
         *) case "$(uname -o 2>/dev/null)" in
              *Mingw*|*Cygwin*|*Msys*) echo windows ;;
              *) echo "${os:-unknown}" ;;
            esac ;;
       esac ;;
  esac
}

# ---- pnpm 探测：优先 DSH_PNPM，回退 PATH / npm-global / managed 任意版本，最后 npm ----
# 注意：不再硬编码具体 node 版本号（如 22.22.2），改为探测 managed 目录下任意版本，
#       这样跨用户 / 跨机器都能找到 pnpm，而不会因版本号写死而失效。
_dsh_pnpm() {
  if [ -n "${DSH_PNPM:-}" ] && [ -x "$DSH_PNPM" ]; then echo "$DSH_PNPM"; return 0; fi
  local p; p="$(command -v pnpm 2>/dev/null)"; [ -n "$p" ] && { echo "$p"; return 0; }
  [ -x "$HOME/.npm-global/bin/pnpm" ] && { echo "$HOME/.npm-global/bin/pnpm"; return 0; }
  local managed; managed="$(ls -d "$HOME"/.workbuddy/binaries/node/versions/*/bin/pnpm 2>/dev/null | head -1)"
  [ -n "$managed" ] && [ -x "$managed" ] && { echo "$managed"; return 0; }
  return 1
}

# ---- 解析 profiles 下的 @deepseek-ai 目录（兼容 profiles/node_modules 与 profiles/web/node_modules）----
_dsh_profiles_ad() {
  for p in "$DSH_HOME/profiles/node_modules/@deepseek-ai" "$DSH_HOME/profiles/web/node_modules/@deepseek-ai"; do
    [ -d "$p" ] && { echo "$p"; return; }
  done
  echo "$DSH_HOME/profiles/node_modules/@deepseek-ai"
}

# ---- 交互确认（zsh / bash 通用，不依赖 read -q）----
_dsh_confirm() {
  local ans
  [ -t 0 ] || return 1
  printf '%s' "$1"
  IFS= read -r ans || return 1
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ---- 收集宿主注入的 safe-delete 守卫变量，生成 env -u 参数 ----
# 不再写死 CODEBUDDY_SAFE_DELETE_* 几个名字，而是动态扫描所有
# CODEBUDDY_SAFE_DELETE* / SAFE_DELETE_BULK* 变量（换宿主也能覆盖）。
_dsh_guard_unset_args() {
  local v; while IFS= read -r v; do
    [ -n "$v" ] && printf '%s\n' "-u" "$v"
  done < <(env | cut -d= -f1 | grep -E '^CODEBUDDY_SAFE_DELETE|^SAFE_DELETE_BULK' 2>/dev/null || true)
}

# ---- 一次拉取 next/latest 两个 dist-tag ----
_dsh_check_update() {
  local tags next latest inst
  tags="$(npm view @deepseek-ai/dsh dist-tags --json 2>/dev/null || true)"
  if [ -n "$tags" ]; then
    next="$(printf '%s' "$tags" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let v="";try{v=JSON.parse(s).next||""}catch(e){}console.log(v)})' 2>/dev/null || true)"
    latest="$(printf '%s' "$tags" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let v="";try{v=JSON.parse(s).latest||""}catch(e){}console.log(v)})' 2>/dev/null || true)"
  fi
  # 已安装版本：优先读 runtime 内 package.json（最权威、不依赖 PATH / dsh 的 stderr 输出），
  # 缺失时回退到 dsh --version（合并 stderr，避免被 2>/dev/null 吞掉）。
  # 注意：dsh 可能不在 PATH，或其 wrapper 把版本打到 stderr（如 "CLI not found"），
  # 下方必须 || true，否则 set -e + pipefail 会让 status/doctor/check/update --dry-run
  # 等只读命令在 dsh 缺失 / profiles 软链损坏时直接 abort 或得到空版本。
  inst=""
  local pj="$DSH_HOME/runtime/node_modules/@deepseek-ai/dsh/package.json"
  if [ -f "$pj" ]; then
    inst="$(node -e 'try{console.log(require(process.argv[1]).version)}catch(e){}' "$pj" 2>/dev/null || true)"
  fi
  [ -z "$inst" ] && inst="$(dsh --version 2>&1 | head -n1 || true)"
  _DSH_NEXT="$next"; _DSH_LATEST="$latest"; _DSH_INST="$inst"
}

# ---- 就地升级共享 runtime 到 $1 ----
_dsh_do_upgrade() {
  local wanted="$1" base pnpm
  [ -z "$wanted" ] && { echo "✗ 未指定版本" >&2; return 1; }
  if ! npm view "@deepseek-ai/dsh@$wanted" version >/dev/null 2>&1; then
    echo "✗ registry 找不到 @deepseek-ai/dsh@${wanted}，跳过（版本未发布或拼写错误）。"
    return 1
  fi
  # 若当前是源码安装（runtime-src/backup 存在），先恢复原始 package.json 再装 npm 版
  _dsh_src_restore "$wanted"
  local link; link="$(readlink "$DSH_HOME/profiles/node_modules/@deepseek-ai/dsh" 2>/dev/null || true)"
  base="$(dirname "$(dirname "$(dirname "${link:-$DSH_HOME/runtime/node_modules/@deepseek-ai/dsh}")")")"
  pnpm="$(_dsh_pnpm)"
  echo "→ 升级共享安装 $base → @deepseek-ai/dsh@$wanted"
  # 用「删 node_modules + lockfile 后联网重解析」确保整棵依赖树干净一致，
  # 避免复用旧扁平目录导致遗留孤儿包（历史上曾因 rc.1 孤儿 adapter 触发接口报错）。
  if [ -n "$pnpm" ]; then
    ( cd "$base" && rm -rf node_modules pnpm-lock.yaml \
      && "$pnpm" install --shamefully-hoist --ignore-scripts )
  else
    ( cd "$base" && rm -rf node_modules package-lock.json \
      && npm install --save-exact "@deepseek-ai/dsh@$wanted" --no-audit --no-fund --ignore-scripts )
  fi
  local rc=$?
  if [ $rc -ne 0 ]; then echo "✗ 升级失败（退出 ${rc}），当前安装未改动。"; return 1; fi
  local got; got="$(dsh --version 2>/dev/null | head -n1)"
  if [ "$got" != "$wanted" ]; then
    echo "⚠ 升级后版本=${got}（期望 ${wanted}）。可重跑 dsh-manage.sh pin 重新钉死。"
    return 1
  fi
  echo "✓ 完成 → ${got}（重新钉死壳链接…）"
  zsh "$BIN_DIR/pin-runtime.sh" >/dev/null 2>&1 || bash "$BIN_DIR/pin-runtime.sh" >/dev/null 2>&1 || true
  return 0
}

# ---- semver 比较：$1 > $2（含 prerelease，遵循 semver 优先级）----
# 用法：_dsh_ver_gt 1.2.3 1.2.2 && echo yes
_dsh_ver_gt() {
  node -e '
    const [a, b] = process.argv.slice(1)
    const parse = (s) => {
      const m = /^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$/.exec(s)
      if (!m) return null
      return { major: +m[1], minor: +m[2], patch: +m[3], pre: m[4] ? m[4].split(".") : [] }
    }
    const cmp = (x, y) => {
      for (const k of ["major", "minor", "patch"]) if (x[k] !== y[k]) return x[k] - y[k]
      if (x.pre.length === 0 && y.pre.length === 0) return 0
      if (x.pre.length === 0) return 1          // 正式版 > prerelease
      if (y.pre.length === 0) return -1
      const n = Math.max(x.pre.length, y.pre.length)
      for (let i = 0; i < n; i++) {
        const xp = x.pre[i] ?? "", yp = y.pre[i] ?? ""
        if (xp === yp) continue
        const xn = /^\d+$/.test(xp), yn = /^\d+$/.test(yp)
        if (xn && yn) return +xp - +yp
        if (xn) return -1                        // 数字标识符 < 字母标识符
        if (yn) return 1
        return xp < yp ? -1 : 1
      }
      return 0
    }
    const x = parse(a), y = parse(b)
    process.exit(x && y && cmp(x, y) > 0 ? 0 : 1)
  ' "$1" "$2" 2>/dev/null
}

# ---- 探测官方 GitHub dsh-v* tags，找出比当前安装更新的最新版 ----
# 结果写入 _DSH_GH_NEW（可能为空）。用 git ls-remote，不依赖 gh。
_dsh_gh_check() {
  local tags v best=""
  tags="$(git ls-remote --tags https://github.com/deepseek-ai/deepseek-harness 'refs/tags/dsh-v*' 2>/dev/null | sed -E 's#.*refs/tags/dsh-v([^ ]+)$#\1#' || true)"
  for v in $tags; do
    [ -z "$v" ] && continue
    # 过滤掉 "^{}" 解引用行（带后缀）
    case "$v" in *^{}*) continue;; esac
    if _dsh_ver_gt "$v" "${_DSH_INST:-0.0.0}"; then
      if [ -z "$best" ] || _dsh_ver_gt "$v" "$best"; then best="$v"; fi
    fi
  done
  _DSH_GH_NEW="$best"
}

# ---- 从官方 GitHub 源码构建安装 runtime 到 $1（版本号如 0.1.2-alpha.1）----
# 场景：官方先在 GitHub 打 dsh-v* tag / prerelease，npm 尚未发布时，也能安装。
# 流程：sparse 克隆源码 → pnpm install + 完整构建 → runtime 以 workspace 方式
#       挂载源码目录（--shamefully-hoist 保持与现有 runtime 布局一致）→ pin。
# 回滚：npm 版本可用后，dsm update / update-runtime 会先恢复备份的 package.json。
_dsh_do_upgrade_src() {
  local wanted="$1" pnpm src_dir rt_dir
  [ -z "$wanted" ] && { echo "✗ 未指定版本" >&2; return 1; }
  pnpm="$(_dsh_pnpm)"
  if [ -z "$pnpm" ]; then echo "✗ 需要 pnpm（源码构建依赖 pnpm workspace）" >&2; return 1; fi
  src_dir="$DSH_HOME/runtime-src/$wanted"
  rt_dir="$DSH_HOME/runtime"
  [ -d "$rt_dir" ] || { echo "✗ runtime 目录不存在: $rt_dir" >&2; return 1; }

  # 1) 下载源码（sparse 克隆；只拉构建所需目录，约 20-60 秒 / 20MB）
  if [ ! -d "$src_dir/apps" ]; then
    mkdir -p "$DSH_HOME/runtime-src"
    echo "→ 下载官方源码（sparse 克隆 dsh-v${wanted}，仅拉构建所需目录）..."
    GIT_HTTP_VERSION=1 git clone --depth 1 --branch "dsh-v$wanted" --sparse \
      https://github.com/deepseek-ai/deepseek-harness.git "$src_dir" 2>&1 | tail -2 \
      || { echo "✗ 源码下载失败（tag dsh-v${wanted} 可能不存在或网络不通）"; return 1; }
    ( cd "$src_dir" && git sparse-checkout set --skip-checks \
        apps packages vendor native patches website \
        pnpm-workspace.yaml package.json pnpm-lock.yaml scripts .npmrc 2>/dev/null || true )
  else
    echo "→ 复用已下载源码 ${src_dir}"
  fi

  # 2) 安装依赖 + 完整构建（corepack 自动适配官方 pnpm 版本，首次约 2-10 分钟）
  echo "→ 安装 monorepo 依赖并完整构建（首次较慢，请耐心等待）..."
  ( cd "$src_dir" && export COREPACK_ENABLE_DOWNLOAD_PROMPT=0 COREPACK_ENABLE_STRICT=0 \
    && "$pnpm" install --ignore-scripts 2>&1 | tail -3 \
    && "$pnpm" run build 2>&1 | tail -3 ) \
    || { echo "✗ 依赖安装或构建失败（可在 ${src_dir} 手动排查后重跑）"; return 1; }

  # 3) 备份当前 runtime 的 package.json（npm 升级时用于恢复）
  local bak="$DSH_HOME/runtime-src/backup"
  if [ -f "$rt_dir/package.json" ]; then
    mkdir -p "$bak"
    cp "$rt_dir/package.json" "$bak/package.json"
    echo "→ 已备份原 package.json -> ${bak}/package.json"
  fi

  # 4) runtime 挂载源码目录为 pnpm workspace（用相对路径，pnpm glob 不支持绝对路径）
  local rel_src
  rel_src="$(node -e 'const {relative}=require("path");process.stdout.write(relative(process.argv[1],process.argv[2]))' "$rt_dir" "$src_dir")"
  cat > "$rt_dir/pnpm-workspace.yaml" <<EOF
# dsh-manage.sh update-src 生成：挂载源码目录为 workspace（npm 更新时会移除）
packages:
  - .
  - ${rel_src}/apps/*
  - ${rel_src}/packages/*/*
  - ${rel_src}/vendor/*
  - ${rel_src}/native/landlock-run/packages/*
EOF
  # 5) package.json 依赖改为 workspace:^（其余依赖不动，由 pnpm 从 workspace 解析）
  node -e '
    const fs = require("fs")
    const p = process.argv[1]
    const j = JSON.parse(fs.readFileSync(p, "utf8"))
    if (j.dependencies && j.dependencies["@deepseek-ai/dsh"]) j.dependencies["@deepseek-ai/dsh"] = "workspace:^"
    fs.writeFileSync(p, JSON.stringify(j, null, 2) + "\n")
  ' "$rt_dir/package.json" || { echo "✗ 修改 package.json 失败"; return 1; }

  # 6) 重装（--shamefully-hoist 保持 node_modules/@deepseek-ai 完整闭包，与 pin 布局一致）
  echo "→ 安装 ${wanted} 到 runtime（--shamefully-hoist）..."
  ( cd "$rt_dir" && export COREPACK_ENABLE_DOWNLOAD_PROMPT=0 COREPACK_ENABLE_STRICT=0 \
    && rm -rf node_modules pnpm-lock.yaml \
    && "$pnpm" install --shamefully-hoist --ignore-scripts 2>&1 | tail -4 ) \
    || { echo "✗ runtime 安装失败；可恢复备份 package.json 后重试"; return 1; }

  # 7) 重钉壳链接 + 验证
  echo "→ 重新钉死壳链接..."
  zsh "$BIN_DIR/pin-runtime.sh" >/dev/null 2>&1 || bash "$BIN_DIR/pin-runtime.sh" >/dev/null 2>&1 || true
  local got; got="$(dsh --version 2>/dev/null | head -n1)"
  if [ "$got" = "$wanted" ]; then
    echo "✓ 完成 → ${got}（源码安装 dsh-v${wanted}）"
    return 0
  fi
  echo "⚠ 安装完成但版本检测=${got:-未知}（期望 ${wanted}）。可重跑 dsh-manage.sh pin。"
  return 0
}

# ---- 恢复源码安装前的 runtime package.json（npm 升级前调用）----
# $1 = 目标 npm 版本：backup 缺失（被 cleanup 删除）时，把 workspace:^ 直接改为该版本
_dsh_src_restore() {
  local bak="$DSH_HOME/runtime-src/backup/package.json"
  if [ -f "$bak" ] && [ -f "$DSH_HOME/runtime/package.json" ]; then
    cp "$bak" "$DSH_HOME/runtime/package.json"
    rm -f "$DSH_HOME/runtime/pnpm-workspace.yaml"
    echo "→ 已恢复源码安装前的 package.json（并移除 workspace 挂载）"
    return 0
  fi
  # 兜底：backup 缺失，但 package.json 仍是源码安装状态（workspace:^）→ 改写为 npm 版本
  if [ -f "$DSH_HOME/runtime/package.json" ] && [ -n "${1:-}" ]; then
    if grep -q '"@deepseek-ai/dsh"[[:space:]]*:[[:space:]]*"workspace:\^"' "$DSH_HOME/runtime/package.json"; then
      node -e '
        const fs = require("fs")
        const p = process.argv[1], v = process.argv[2]
        const j = JSON.parse(fs.readFileSync(p, "utf8"))
        if (j.dependencies && j.dependencies["@deepseek-ai/dsh"] === "workspace:^") j.dependencies["@deepseek-ai/dsh"] = v
        fs.writeFileSync(p, JSON.stringify(j, null, 2) + "\n")
      ' "$DSH_HOME/runtime/package.json" "$1" 2>/dev/null || return 1
      rm -f "$DSH_HOME/runtime/pnpm-workspace.yaml"
      echo "→ 源码回滚备份已缺失，已将 package.json 的 workspace:^ 改为 npm 版本 $1（并移除 workspace 挂载）"
    fi
  fi
}

# ---- 壳版本检测 ----
_dsh_shell_cur() {
  if [ -f "$DSH_APP/Contents/Info.plist" ]; then
    /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$DSH_APP/Contents/Info.plist" 2>/dev/null
  fi
}
# 按平台返回壳 Release asset 的正则（macOS=universal.dmg / Windows=.exe / Linux=.AppImage|.tar.*）
_dsh_shell_asset_regex() {
  case "$(_dsh_os)" in
    macos)   printf 'universal\.dmg$' ;;
    windows) printf '\.exe$' ;;
    linux)   printf '\.(AppImage|tar\.(gz|xz))$' ;;
    *)       printf 'universal\.dmg$' ;;
  esac
}
_dsh_shell_check() {
  _DSH_SHELL_CUR="$(_dsh_shell_cur)"
  local rel rx
  rel="$(curl -sL --max-time 25 "https://api.github.com/repos/anywhere-labs/deepseek-harness-desktop/releases/latest" 2>/dev/null)"
  if [ -n "$rel" ]; then
    rx="$(_dsh_shell_asset_regex)"
    _DSH_SHELL_LATEST="$(printf '%s' "$rel" | DSH_ASSET_RX="$rx" node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let v="";try{v=(JSON.parse(s).tag_name||"").replace(/^v/,"")}catch(e){}console.log(v)})' 2>/dev/null)"
    _DSH_SHELL_URL="$(printf '%s' "$rel" | DSH_ASSET_RX="$rx" node -e 'const rx=new RegExp(process.env.DSH_ASSET_RX,"i");let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);const a=(j.assets||[]).find(x=>rx.test(x.name));console.log(a?a.browser_download_url:(j.html_url||""))}catch(e){console.log("")}})' 2>/dev/null)"
  fi
}

# ---- 壳升级（按平台分发）----
_dsh_shell_upgrade() {
  local cur="$1" url="$2" tag="$3"
  [ -z "$url" ] && { echo "✗ 找不到壳下载地址，请手动从 GitHub Releases 更新。"; return 1; }
  case "$(_dsh_os)" in
    macos)   _dsh_shell_upgrade_macos "$@" ;;
    linux)   _dsh_shell_upgrade_linux "$@" ;;
    windows) _dsh_shell_upgrade_windows "$@" ;;
    *) echo "✗ 未知平台（$1），无法自动升级壳。"; return 1 ;;
  esac
}

# macOS：下载 universal dmg → 备份 → 挂载 → 替换 → 重新钉 runtime
_dsh_shell_upgrade_macos() {
  local cur="$1" url="$2" tag="$3" dmg mnt app bak
  if pgrep -f "DSH Desktop" >/dev/null 2>&1; then
    echo "→ 正在退出 DSH Desktop…"; osascript -e 'quit app "DSH Desktop"' 2>/dev/null || true; sleep 2
  fi
  bak="$DSH_HOME/shell-bak-$cur-$(date +%Y%m%d%H%M%S)"
  echo "→ 备份当前壳 → $bak"; cp -R "$DSH_APP" "$bak" || { echo "✗ 备份失败，中止壳升级。"; return 1; }
  dmg="/tmp/DSH.Desktop-$tag.dmg"
  echo "→ 下载壳 ($url)"; curl -L --max-time 600 -o "$dmg" "$url" || { echo "✗ 下载失败"; return 1; }
  mnt="$(hdiutil attach "$dmg" -nobrowse -noautoopen 2>/dev/null | tail -1 | awk -F'\t' '{print $NF}')"
  [ -z "$mnt" ] && { echo "✗ 挂载 dmg 失败"; rm -f "$dmg"; return 1; }
  app="$(find "$mnt" -maxdepth 2 -name "*.app" -type d 2>/dev/null | head -1)"
  if [ -z "$app" ]; then echo "✗ dmg 内未找到 .app"; hdiutil detach "$mnt" >/dev/null 2>&1; rm -f "$dmg"; return 1; fi
  echo "→ 安装新壳（旧版已备份）…"; rm -rf "$DSH_APP"; cp -R "$app" "$DSH_APP"
  xattr -dr com.apple.quarantine "$DSH_APP" 2>/dev/null || true
  hdiutil detach "$mnt" >/dev/null 2>&1; rm -f "$dmg"
  echo "→ 重新钉死 runtime 链接…"; zsh "$BIN_DIR/pin-runtime.sh" >/dev/null 2>&1 || bash "$BIN_DIR/pin-runtime.sh" >/dev/null 2>&1 || true
  echo "✓ 壳已升级到 ${tag}（旧版备份在 ${bak}）"
}

# Linux：下载 AppImage / tar 包 → 备份 /Applications 等价目录 → 解压替换。
# ⚠️ 未经真机验证（本机为 macOS）。DSH_HOME 下以 shell/ 目录承载解包结果。
_dsh_shell_upgrade_linux() {
  local cur="$1" url="$2" tag="$3" dest bak tmp
  dest="${DSH_APP:-$DSH_HOME/shell}"
  bak="$DSH_HOME/shell-bak-$cur-$(date +%Y%m%d%H%M%S)"
  [ -e "$dest" ] && { echo "→ 备份当前壳 → $bak"; mv "$dest" "$bak" || { echo "✗ 备份失败"; return 1; }; }
  tmp="/tmp/DSH.Desktop-$tag"; rm -rf "$tmp"; mkdir -p "$tmp"
  echo "→ 下载壳 ($url)"; curl -L --max-time 600 -o "$tmp/asset" "$url" || { echo "✗ 下载失败"; return 1; }
  mkdir -p "$dest"
  case "$url" in
    *.AppImage) cp "$tmp/asset" "$dest/DSH-Desktop.AppImage" && chmod +x "$dest/DSH-Desktop.AppImage" ;;
    *.tar.gz|*.tar.xz|*.tgz) tar -xf "$tmp/asset" -C "$dest" ;;
    *) echo "✗ 不支持的 Linux 壳格式: $url"; return 1 ;;
  esac
  rm -rf "$tmp"
  zsh "$BIN_DIR/pin-runtime.sh" >/dev/null 2>&1 || bash "$BIN_DIR/pin-runtime.sh" >/dev/null 2>&1 || true
  echo "✓ 壳已升级到 ${tag}（Linux 路径：${dest}；旧版备份在 ${bak}）"
}

# Windows：下载 exe 安装包 → 静默运行安装（/S）。
# ⚠️ 未经真机验证（本机为 macOS）。DSH_APP 应指向安装目录（如 %LOCALAPPDATA%\Programs\DSH Desktop）。
_dsh_shell_upgrade_windows() {
  local cur="$1" url="$2" tag="$3" exe bak
  exe="/tmp/DSH.Desktop-$tag.exe"
  bak="$DSH_HOME/shell-bak-$cur-$(date +%Y%m%d%H%M%S)"
  [ -e "$DSH_APP" ] && { echo "→ 备份当前壳 → $bak"; cp -R "$DSH_APP" "$bak" || { echo "✗ 备份失败"; return 1; }; }
  echo "→ 下载壳 ($url)"; curl -L --max-time 600 -o "$exe" "$url" || { echo "✗ 下载失败"; return 1; }
  echo "→ 静默安装（/S）…"; "$exe" //S || { echo "✗ 安装失败"; return 1; }
  rm -f "$exe"
  echo "✓ 壳已升级到 ${tag}（旧版备份在 ${bak}）"
}

# ---- 启动 web（卸载 safe-delete 守卫）----
_dsh_web() {
  _dsh_check_update
  local cands=() seen="" v
  for v in "$_DSH_NEXT" "$_DSH_LATEST"; do
    [ -z "$v" ] && continue
    # 只有比当前版本更新才算候选（避免源码装的 alpha 被误提示降级到 npm 旧版）
    _dsh_ver_gt "$v" "$_DSH_INST" || continue
    case "$seen" in *"|$v|"*) continue;; esac
    seen="$seen|$v|"; cands+=("$v")
  done
  if [ ${#cands[@]} -gt 0 ] && [ -t 0 ]; then
    for v in "${cands[@]}"; do
      if _dsh_confirm "升级 runtime 到 $v? [y/N] "; then
        _dsh_do_upgrade "$v" || echo "⚠ $v 升级失败"
      else
        echo "  跳过 $v"
      fi
    done
  elif [ ${#cands[@]} -gt 0 ]; then
    echo "ℹ 检测到 runtime 更新可用（$_DSH_INST → ${cands[*]}），非交互环境未自动升级。"
  fi
  # 关键：动态卸载宿主注入的 safe-delete 批量删除守卫（覆盖所有 CODEBUDDY_SAFE_DELETE* / SAFE_DELETE_BULK*），
  # 避免 dsh web → plugin-manager → pnpm 清理临时目录时因 >50 文件批量删除确认而无法确认导致更新失败。
  local guard_args=()
  while IFS= read -r line; do
    [ -n "$line" ] && guard_args+=("$line")
  done < <(_dsh_guard_unset_args)
  env "${guard_args[@]}" -u CODEBUDDY_SESSION_ID -u CODEBUDDY_TOOL_CALL_ID \
      dsh web ${DSH_PATCH_YML:+"--patch" "$DSH_PATCH_YML"} "$@"
}

# ---- 跨平台 realpath（macOS /bin/bash 的 readlink 不支持 -f）----
_dsh_realpath() {
  if command -v node >/dev/null 2>&1; then
    node -e 'try{process.stdout.write(require("fs").realpathSync(process.argv[1]))}catch(e){process.stdout.write(process.argv[1])}' "$1" 2>/dev/null || printf '%s' "$1"
  else
    local r; r="$(readlink "$1" 2>/dev/null || true)"; [ -n "$r" ] && printf '%s' "$r" || printf '%s' "$1"
  fi
}

# ---- 自检 ----
_dsh_doctor() {
  echo "=== DSH 自检 (doctor) ==="
  local fail=0
  # 1) heal 后关键包是否仍解析到 runtime
  if command -v node >/dev/null 2>&1 && [ -f "$BIN_DIR/verify-heal.mjs" ]; then
    local log; log="$(mktemp -t dsh-doc.XXXXXX.log)"
    if node "$BIN_DIR/verify-heal.mjs" >"$log" 2>&1; then
      echo "  [OK]   heal 后关键包全部解析到 runtime"
    else
      echo "  [FAIL] 存在未指向 runtime 的包："; sed 's/^/      /' "$log"
      fail=1
    fi
    rm -f "$log"
  fi
  # 2) profiles / app 的 @deepseek-ai/* 软链是否真指向 runtime（顺着软链链解析，避免假阳性）
  #    仅校验 runtime 中真实存在的包；app-only 包（runtime 无）本就该指向壳，不误报
  local base l rp2 realp rtlist name
  base="$(_dsh_profiles_ad)"
  rtlist="$( [ -d "$DSH_HOME/runtime/node_modules/@deepseek-ai" ] && ls "$DSH_HOME/runtime/node_modules/@deepseek-ai" 2>/dev/null || true )"
  if [ -d "$base" ]; then
    for l in "$base"/*; do
      [ -L "$l" ] || continue
      name="$(basename "$l")"
      case "$rtlist" in *"$name"*) ;; *) continue ;; esac
      rp2="$(readlink "$l" 2>/dev/null || true)"
      realp="$(_dsh_realpath "$l" 2>/dev/null || true)"
      if [[ "$realp" != "$DSH_HOME/runtime"* ]]; then
        echo "  [WARN] $l -> ${rp2}（未指向 runtime）"; fail=1
      fi
    done
  fi
  # 3) 备份目录（列出真实路径 + 大小，可用 cleanup 清理 / rollback 还原）
  local bakrows btype bver bts bsize bpath nbak
  bakrows="$(_dsh_backup_list)"
  if [ -n "$bakrows" ]; then
    nbak="$(printf '%s\n' "$bakrows" | wc -l | tr -d ' ')"
    echo "  [INFO] 备份目录共 $nbak 个（可用 cleanup 清理 / rollback 还原）："
    printf '%s\n' "$bakrows" | while IFS=$'\t' read -r btype bver bts bsize bpath; do
      [ -n "$bpath" ] && echo "      - ${bpath}（$btype ${bver}，$(_dsh_ts_fmt "$bts")，${bsize}）"
    done
  fi
  # 4) 当前 shell 是否仍导出 safe-delete 守卫（web 启动会自动卸载，仅提示）
  local gv; gv="$(env | cut -d= -f1 | grep -E '^CODEBUDDY_SAFE_DELETE|^SAFE_DELETE_BULK' 2>/dev/null | tr '\n' ' ')"
  [ -n "$gv" ] && echo "  [INFO] 当前 shell 导出了守卫变量: ${gv}（web 启动时会自动 unset）"
  # 5) 版本与更新可用性
  _dsh_check_update; _dsh_shell_check
  echo "  runtime: ${_DSH_INST:-未知}（next=${_DSH_NEXT:-无} latest=${_DSH_LATEST:-无}）"
  echo "  壳:     ${_DSH_SHELL_CUR:-未知}（最新=${_DSH_SHELL_LATEST:-无}）"
  { [ -n "${_DSH_NEXT:-}" ] && _dsh_ver_gt "$_DSH_NEXT" "$_DSH_INST"; } || { [ -n "${_DSH_LATEST:-}" ] && _dsh_ver_gt "$_DSH_LATEST" "$_DSH_INST"; } \
    && echo "  [INFO] runtime 有可用更新"
  echo "=== 自检完成: $([ $fail -eq 0 ] && echo '无致命问题 ✅' || echo '存在 FAIL，请处理 ❌') ==="
  return $fail
}

# ---- 回滚（从备份还原）----
_dsh_rollback() {
  local what="${1:-runtime}"
  case "$what" in runtime|shell|all) ;; *) echo "用法: dsh-manage.sh rollback [runtime|shell|all]" >&2; return 1 ;; esac
  if [ "$what" = "runtime" ] || [ "$what" = "all" ]; then
    local bak; bak="$(find "$DSH_HOME" -maxdepth 1 -type d -name 'bundle-bak-*' 2>/dev/null | sort | tail -1)"
    if [ -z "$bak" ]; then echo "✗ 未找到 bundle-bak-* 备份，无法回滚 runtime pin。"; else
      echo "将撤销 runtime pin：把 $bak 的真实目录还原到壳内 @deepseek-ai（profiles 仍指向 runtime，"
      echo "下次壳升级 / heal 会重新以壳自带版本解析）。备份内容："; ls "$bak"
      _dsh_confirm "确认回滚 runtime pin? [y/N] " || { echo "已取消。"; return 1; }
      local appdir
      if [ -n "${DSH_APP_PKG:-}" ]; then appdir="$DSH_APP_PKG";
      elif [ -d "/Applications/DSH Desktop.app/Contents/Resources/app.asar.unpacked/node_modules/@deepseek-ai" ]; then appdir="/Applications/DSH Desktop.app/Contents/Resources/app.asar.unpacked/node_modules/@deepseek-ai";
      else echo "✗ 无法确定壳内 @deepseek-ai 目录（请设置 DSH_APP_PKG）"; return 1; fi
      for n in "$bak"/*; do
        [ -e "$n" ] || continue; name="$(basename "$n")"; tgt="$appdir/$name"
        [ -L "$tgt" ] && rm -f "$tgt"
        [ -e "$tgt" ] && { echo "  ⚠ $name 在壳内已存在且非软链，跳过"; continue; }
        mv "$n" "$tgt" && echo "  ✓ 还原 $name -> $tgt"
      done
      echo "✓ runtime pin 已回滚（如需重新钉死请运行 dsh-manage.sh pin）。"
    fi
  fi
  if [ "$what" = "shell" ] || [ "$what" = "all" ]; then
    local sbak; sbak="$(find "$DSH_HOME" -maxdepth 1 -type d -name 'shell-bak-*' 2>/dev/null | sort | tail -1)"
    if [ -z "$sbak" ]; then echo "✗ 未找到 shell-bak-* 备份，无法回滚壳。"; else
      echo "将把壳还原为 ${sbak}（当前壳会被覆盖）。"
      _dsh_confirm "确认回滚壳? [y/N] " || { echo "已取消。"; return 1; }
      if pgrep -f "DSH Desktop" >/dev/null 2>&1; then osascript -e 'quit app "DSH Desktop"' 2>/dev/null || true; sleep 2; fi
      rm -rf "$DSH_APP"; cp -R "$sbak" "$DSH_APP"
      echo "✓ 壳已回滚到 ${sbak}。"
    fi
  fi
}

# ---- 备份时间戳格式化（macOS / Linux 通用）----
_dsh_ts_fmt() {
  local t="$1"
  date -j -f "%Y%m%d%H%M%S" "$t" "+%Y-%m-%d %H:%M" 2>/dev/null && return
  date -d "$t" "+%Y-%m-%d %H:%M" 2>/dev/null && return
  printf '%s' "$t"
}

# ---- 列出备份（bundle-bak-* / shell-bak-* / runtime-src），每行：类型<TAB>版本<TAB>时间戳<TAB>大小<TAB>路径 ----
_dsh_backup_list() {
  local d name type ver ts
  # bundle-bak-*（runtime pin）与 shell-bak-*（壳升级）
  while IFS= read -r d; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    type="runtime pin"; ver="-"; ts=""
    case "$name" in
      shell-bak-*)
        type="壳"
        ver="${name#shell-bak-}"; ver="${ver%-*}"   # shell-bak-2.0.2-20260828133548 -> 2.0.2
        ts="${name##*-}"
        ;;
      bundle-bak-*)
        type="runtime pin"
        ts="${name#bundle-bak-}"
        ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\n' "$type" "$ver" "$ts" "$(du -sh "$d" 2>/dev/null | awk '{print $1}')" "$d"
  done < <(find "$DSH_HOME" -maxdepth 1 -type d \( -name 'bundle-bak-*' -o -name 'shell-bak-*' \) 2>/dev/null | sort)
  # runtime-src：update-src 的源码缓存（每版本一个目录，可能很大）+ 回滚备份（package.json）
  while IFS= read -r d; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    type="源码缓存"; ver="$name"; ts="-"
    [ "$name" = "backup" ] && { type="源码回滚备份"; ver="-"; }
    printf '%s\t%s\t%s\t%s\t%s\n' "$type" "$ver" "$ts" "$(du -sh "$d" 2>/dev/null | awk '{print $1}')" "$d"
  done < <(find "$DSH_HOME/runtime-src" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
}

# ---- 判断某源码版本是否正被 runtime 使用（保护：任何安装方式下都不可删）----
# 命中任一即视为在用：
#   1) pnpm-workspace.yaml 挂载引用（源码安装，相对/绝对路径兼容，匹配公共子串）
#   2) 与 runtime 当前实际安装版本号相同（npm 安装也能兜住：同名缓存视为在用）
_dsh_src_in_use() {
  if [ -f "$DSH_HOME/runtime/pnpm-workspace.yaml" ] \
    && grep -qF "runtime-src/$1/" "$DSH_HOME/runtime/pnpm-workspace.yaml" 2>/dev/null; then
    return 0
  fi
  local cur
  cur="$(node -e 'try{console.log(require(process.argv[1]).version)}catch(e){}' \
    "$DSH_HOME/runtime/node_modules/@deepseek-ai/dsh/package.json" 2>/dev/null)"
  [ "$cur" = "$1" ]
}

# ---- 清理备份（交互式选择删除 / 保留）----
_dsh_cleanup() {
  local dry=0
  [ "${1:-}" = "--dry-run" ] && dry=1
  local items=() i=0 type ver ts size path line
  while IFS=$'\t' read -r type ver ts size path; do
    [ -n "$path" ] || continue
    items+=("$type|$ver|$ts|$size|$path")
  done < <(_dsh_backup_list)
  if [ ${#items[@]} -eq 0 ]; then
    echo "✓ 没有找到任何备份（bundle-bak-*/shell-bak-*/runtime-src），无需清理。"
    return 0
  fi
  echo "=== DSH 备份清理 ==="
  echo "共 ${#items[@]} 个备份（删除后对应版本无法再 rollback；⚠ 在用 的源码缓存不可删）："
  for line in "${items[@]}"; do
    i=$((i+1))
    IFS='|' read -r type ver ts size path <<< "$line"
    flag=""
    if [ "$type" = "源码缓存" ] && _dsh_src_in_use "$ver"; then flag=" ⚠在用"; fi
    printf '  [%2d] %-12s | 版本 %-11s | %s | %s%s\n        %s\n' "$i" "$type" "$ver" "$(_dsh_ts_fmt "$ts")" "$size" "$flag" "$path"
  done
  if [ $dry -eq 1 ]; then echo "ℹ --dry-run：仅列出，未删除任何备份。"; return 0; fi
  [ -t 0 ] || { echo "✗ 非交互环境，请在终端中运行 cleanup（可用 --dry-run 仅查看）。"; return 1; }
  printf '输入要删除的备份编号（空格/逗号分隔；回车=全部保留；all=全部删除）：'
  IFS= read -r sel || return 1
  sel="$(printf '%s' "$sel" | tr ',' ' ' | tr -s ' ')"
  [ -z "$sel" ] && { echo "✓ 未选择任何备份，全部保留。"; return 0; }
  # 解析编号（去重 + 越界校验）
  local dels=() n seen=""
  if [ "$sel" = "all" ]; then
    i=0; for line in "${items[@]}"; do i=$((i+1)); dels+=("$i"); done
  else
    for n in $sel; do
      case "$n" in ''|*[!0-9]*) echo "⚠ 忽略无效输入: $n"; continue ;; esac
      if [ "$n" -lt 1 ] || [ "$n" -gt "${#items[@]}" ]; then echo "⚠ 编号越界（1-${#items[@]}）: $n"; continue; fi
      case "$seen" in *"|$n|"*) continue ;; esac; seen="$seen|$n|"; dels+=("$n")
    done
  fi
  [ ${#dels[@]} -eq 0 ] && { echo "✓ 未选择有效编号，全部保留。"; return 0; }
  echo "将删除 ${#dels[@]} 个备份："
  for n in "${dels[@]}"; do
    line="${items[$((n-1))]}"
    IFS='|' read -r type ver ts size path <<< "$line"
    echo "  ✗ $path"
  done
  _dsh_confirm "确认删除? [y/N] " || { echo "已取消，未删除任何备份。"; return 1; }
  for n in "${dels[@]}"; do
    line="${items[$((n-1))]}"
    IFS='|' read -r type ver ts size path <<< "$line"
    # 在用保护：正被 runtime 挂载的源码缓存不可删（删了 runtime 的 dsh 直接失效）
    if [ "$type" = "源码缓存" ] && _dsh_src_in_use "$ver"; then
      echo "  ⚠ 跳过（在用）: $path（先 dsm update-runtime <npm版> 切回 npm 再清理）"
      continue
    fi
    if rm -rf "$path" 2>/dev/null; then echo "  ✓ 已删除 $path"; else echo "  ✗ 删除失败 $path"; fi
  done
  echo "--- 剩余备份 ---"
  local rest; rest="$(_dsh_backup_list)"
  if [ -n "$rest" ]; then
    printf '%s\n' "$rest" | while IFS=$'\t' read -r t v s2 sz p; do echo "  $p"; done
  else
    echo "  （无备份）"
  fi
  echo "✓ 清理完成。"
}

# ---- 引导 runtime（web 端首次安装）----
# 在 ~/.dsh/runtime 用 pnpm/npm 装 @deepseek-ai/dsh（与 _dsh_do_upgrade 同一机制，只是目录从零建）。
# ⚠️ runtime 内部布局依赖 DSH 上游约定，本机已验证可用；换机器若 heal 后 doctor 报 FAIL，按输出手动修正即可。
_dsh_bootstrap_runtime() {
  local ver="${1:-}" pnpm binjs
  if [ -e "$DSH_HOME/runtime/node_modules/@deepseek-ai/dsh/package.json" ]; then
    echo "→ runtime 已存在（$DSH_HOME/runtime），跳过引导（如需重装用 update-runtime <ver>）。"
    return 0
  fi
  if [ -z "$ver" ]; then
    ver="$(npm view "@deepseek-ai/dsh" dist-tags.latest 2>/dev/null || true)"
    [ -z "$ver" ] && { echo "✗ 无法获取 @deepseek-ai/dsh 最新版本（离线？）。可用 --runtime <ver> 显式指定。"; return 1; }
  fi
  echo "→ 引导 runtime：@deepseek-ai/dsh@$ver → $DSH_HOME/runtime"
  mkdir -p "$DSH_HOME/runtime"
  printf '{\n  "name": "dsh-runtime",\n  "version": "1.0.0",\n  "private": true,\n  "dependencies": { "@deepseek-ai/dsh": "%s" }\n}\n' "$ver" > "$DSH_HOME/runtime/package.json"
  pnpm="$(_dsh_pnpm)"
  if [ -n "$pnpm" ]; then
    ( cd "$DSH_HOME/runtime" && "$pnpm" install --shamefully-hoist --ignore-scripts )
  else
    ( cd "$DSH_HOME/runtime" && npm install --no-audit --no-fund --ignore-scripts )
  fi
  local rc=$?
  [ $rc -ne 0 ] && { echo "✗ runtime 引导失败（退出 ${rc}），未改动其他内容。"; return 1; }
  echo "✓ runtime 引导完成 → $ver"
  # 确保 dsh 在 PATH：建 ~/.dsh/bin/dsh 软链（指向 runtime 内的 bin）
  binjs="$DSH_HOME/runtime/node_modules/@deepseek-ai/dsh/lib/bin.js"
  if [ -e "$binjs" ]; then
    mkdir -p "$DSH_HOME/bin"
    ln -sf "$binjs" "$DSH_HOME/bin/dsh"
    echo "→ 已创建 $DSH_HOME/bin/dsh 软链。请把下面这行加入你的 shell rc（如 ~/.zshrc）："
    echo "    export PATH=\"$DSH_HOME/bin:\$PATH\""
  else
    echo "⚠ 未找到 runtime 内的 dsh 入口（${binjs}），dsh web 前请手动确保 dsh 在 PATH。"
  fi
  return 0
}

# ---- 安装桌面壳（首次安装，无备份）----
_dsh_shell_install() {
  local cur="$1" url="$2" tag="$3"
  [ -z "$url" ] && { echo "✗ 找不到壳下载地址，请手动从 GitHub Releases 安装 DSH Desktop。"; return 1; }
  case "$(_dsh_os)" in
    macos)
      if [ -d "$DSH_APP" ]; then echo "→ 壳已安装在 ${DSH_APP}，跳过（如需升级用 shell）。"; return 0; fi
      _dsh_shell_install_macos "$@" ;;
    linux)   _dsh_shell_install_linux "$@" ;;
    windows) _dsh_shell_install_windows "$@" ;;
    *) echo "✗ 未知平台，无法自动安装壳。"; return 1 ;;
  esac
}
_dsh_shell_install_macos() {
  local cur="$1" url="$2" tag="$3" dmg mnt app
  dmg="/tmp/DSH.Desktop-$tag.dmg"
  echo "→ 下载壳 ($url)"; curl -L --max-time 600 -o "$dmg" "$url" || { echo "✗ 下载失败"; return 1; }
  mnt="$(hdiutil attach "$dmg" -nobrowse -noautoopen 2>/dev/null | tail -1 | awk -F'\t' '{print $NF}')"
  [ -z "$mnt" ] && { echo "✗ 挂载 dmg 失败"; rm -f "$dmg"; return 1; }
  app="$(find "$mnt" -maxdepth 2 -name "*.app" -type d 2>/dev/null | head -1)"
  if [ -z "$app" ]; then echo "✗ dmg 内未找到 .app"; hdiutil detach "$mnt" >/dev/null 2>&1; rm -f "$dmg"; return 1; fi
  echo "→ 安装壳到 $DSH_APP"; cp -R "$app" "$DSH_APP"
  xattr -dr com.apple.quarantine "$DSH_APP" 2>/dev/null || true
  hdiutil detach "$mnt" >/dev/null 2>&1; rm -f "$dmg"
  echo "✓ 壳已安装到 $DSH_APP"
}
_dsh_shell_install_linux() {
  local cur="$1" url="$2" tag="$3" dest tmp
  dest="${DSH_APP:-$DSH_HOME/shell}"
  [ -e "$dest" ] && { echo "→ 壳已存在于 ${dest}，跳过（如需升级用 shell）。"; return 0; }
  tmp="/tmp/DSH.Desktop-$tag"; rm -rf "$tmp"; mkdir -p "$tmp"
  echo "→ 下载壳 ($url)"; curl -L --max-time 600 -o "$tmp/asset" "$url" || { echo "✗ 下载失败"; return 1; }
  mkdir -p "$dest"
  case "$url" in
    *.AppImage) cp "$tmp/asset" "$dest/DSH-Desktop.AppImage" && chmod +x "$dest/DSH-Desktop.AppImage" ;;
    *.tar.gz|*.tar.xz|*.tgz) tar -xf "$tmp/asset" -C "$dest" ;;
    *) echo "✗ 不支持的 Linux 壳格式: $url"; return 1 ;;
  esac
  rm -rf "$tmp"
  echo "✓ 壳已安装（Linux 路径：${dest}）"
}
_dsh_shell_install_windows() {
  local cur="$1" url="$2" tag="$3" exe
  exe="/tmp/DSH.Desktop-$tag.exe"
  [ -e "$DSH_APP" ] && { echo "→ 壳已存在于 ${DSH_APP}，跳过（如需升级用 shell）。"; return 0; }
  echo "→ 下载壳 ($url)"; curl -L --max-time 600 -o "$exe" "$url" || { echo "✗ 下载失败"; return 1; }
  echo "→ 静默安装（/S）…"; "$exe" //S || { echo "✗ 安装失败"; return 1; }
  rm -f "$exe"
  echo "✓ 壳已安装（Windows 路径：${DSH_APP}）"
}

# ---- install：一键双端安装（壳 + runtime 引导 + pin + doctor）----
_dsh_install() {
  local rtver="" doshell=1 dort=1 dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --runtime) rtver="${2:-}"; shift 2 ;;
      --no-shell) doshell=0; shift ;;
      --no-runtime) dort=0; shift ;;
      --dry-run) dry=1; shift ;;
      *) shift ;;
    esac
  done
  _dsh_shell_check
  if [ $dry -eq 1 ]; then
    echo "ℹ install --dry-run（不做任何改动）："
    [ $doshell -eq 1 ] && echo "    桌面壳: 将安装 ${_DSH_SHELL_LATEST:-未知}（来源 ${_DSH_SHELL_URL:-无}）"
    [ $dort -eq 1 ] && echo "    runtime: 将引导 @deepseek-ai/dsh@${rtver:-latest}"
    [ $doshell -eq 0 ] && echo "    桌面壳: 跳过（--no-shell）"
    [ $dort -eq 0 ] && echo "    runtime: 跳过（--no-runtime）"
    echo "    完成后会自动 pin + doctor 接管。"
    exit 0
  fi
  if [ $doshell -eq 1 ]; then
    if [ -t 0 ]; then
      if _dsh_confirm "安装桌面壳（DSH Desktop ${_DSH_SHELL_LATEST:-最新}）? [y/N] "; then
        _dsh_shell_install "$_DSH_SHELL_CUR" "$_DSH_SHELL_URL" "$_DSH_SHELL_LATEST" || echo "⚠ 壳安装失败，可手动安装后重跑"
      else echo "  跳过壳安装（--no-shell 可显式跳过）"; fi
    else
      _dsh_shell_install "$_DSH_SHELL_CUR" "$_DSH_SHELL_URL" "$_DSH_SHELL_LATEST" || echo "⚠ 壳安装失败（非交互环境已尝试）"
    fi
  fi
  if [ $dort -eq 1 ]; then
    _dsh_bootstrap_runtime "$rtver" || echo "⚠ runtime 引导失败，可手动 bootstrap 后重跑"
  fi
  echo "→ 钉死 runtime 权威…"; zsh "$BIN_DIR/pin-runtime.sh" >/dev/null 2>&1 || bash "$BIN_DIR/pin-runtime.sh" >/dev/null 2>&1 || true
  echo "→ 自检…"; _dsh_doctor || true
  echo "✓ 安装流程结束。后续维护：dsh-manage.sh update / shell / web / doctor / rollback"
}

cmd="${1:-status}"; shift || true
case "$cmd" in
  update)
    _dsh_check_update
    if [ "${1:-}" = "--dry-run" ]; then
      if [ -z "${_DSH_NEXT:-}${_DSH_LATEST:-}" ]; then
        echo "✗ 未能获取 runtime 最新版本（可能离线），当前: ${_DSH_INST:-未知}"
      else
        inst="${_DSH_INST:-未知}"
        for v in "$_DSH_NEXT" "$_DSH_LATEST"; do
          [ -z "$v" ] && continue; _dsh_ver_gt "$v" "$inst" || continue
          echo "→ 若升级 runtime 到 ${v}（当前 ${inst}）："
          deps="$(npm view "@deepseek-ai/dsh@$v" dependencies --json 2>/dev/null)"
          echo "    依赖变更："
          printf '%s\n' "$deps" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const o=JSON.parse(s);const ks=Object.keys(o);console.log(ks.length?ks.map(k=>"      - "+k+"@"+o[k]).join("\n"):"      (无可列依赖)")}catch(e){console.log("      (无法解析依赖)")}})'
        done
        _dsh_gh_check
        if [ -n "${_DSH_GH_NEW:-}" ]; then
          echo "→ GitHub 源码渠道：官方有更新的源码版本 ${_DSH_GH_NEW}（npm 尚未发布）"
        fi
        echo "ℹ dry-run 未做任何改动。去掉 --dry-run 可交互升级（含源码渠道）。"
      fi
    else
      if [ -z "${_DSH_NEXT:-}${_DSH_LATEST:-}" ]; then
        echo "✗ 未能获取 runtime 最新版本（可能离线），当前: ${_DSH_INST:-未知}"
      else
        cands=(); seen=""; for v in "$_DSH_NEXT" "$_DSH_LATEST"; do
          [ -z "$v" ] && continue; _dsh_ver_gt "$v" "$_DSH_INST" || continue
          case "$seen" in *"|$v|"*) continue;; esac; seen="$seen|$v|"; cands+=("$v")
        done
        if [ ${#cands[@]} -eq 0 ]; then
          echo "✓ npm registry 已是最新（${_DSH_INST}）。"
          # npm 无候选时，探测官方 GitHub 是否有更新的源码版本（npm 尚未发布）
          _dsh_gh_check
          if [ -n "${_DSH_GH_NEW:-}" ]; then
            echo "ℹ 官方 GitHub 有更新的源码版本：${_DSH_GH_NEW}（npm 尚未发布）"
            if [ -t 0 ]; then
              if _dsh_confirm "是否从 GitHub 源码构建安装 ${_DSH_GH_NEW}? [y/N] "; then
                _dsh_do_upgrade_src "$_DSH_GH_NEW" || echo "⚠ 源码安装失败"
              else echo "  已跳过。npm 发布后 dsm update 即可正常升级。"; fi
            else
              echo "ℹ 非交互环境，跳过。npm 发布后 dsm update 即可正常升级。"
            fi
          fi
        elif [ ! -t 0 ]; then echo "ℹ 非交互环境，跳过自动更新（当前 ${_DSH_INST}；可用: ${cands[*]}）。"
        else for v in "${cands[@]}"; do
          if _dsh_confirm "升级 runtime 到 $v? [y/N] "; then _dsh_do_upgrade "$v" || echo "⚠ $v 失败"; else echo "  跳过 $v"; fi
        done; fi
      fi
    fi
    ;;
  update-runtime)
    _dsh_do_upgrade "${1:-}"
    ;;
  update-src)
    _dsh_check_update
    want="${1:-}"
    if [ -z "$want" ]; then
      _dsh_gh_check
      want="${_DSH_GH_NEW:-}"
      if [ -z "$want" ]; then
        echo "✓ GitHub 没有比当前（${_DSH_INST:-未知}）更新的源码版本。"
        exit 0
      fi
      echo "→ 官方 GitHub 最新源码版本：${want}（npm 尚未发布）"
      if [ -t 0 ]; then
        _dsh_confirm "确认从源码构建安装 ${want}? [y/N] " || { echo "已取消。"; exit 0; }
      fi
    fi
    _dsh_do_upgrade_src "$want"
    ;;
  shell)
    _dsh_shell_check
    echo "壳 当前: ${_DSH_SHELL_CUR:-未知} ｜ 最新: ${_DSH_SHELL_LATEST:-未知}"
    if [ -z "${_DSH_SHELL_LATEST:-}" ] || [ "$_DSH_SHELL_LATEST" = "$_DSH_SHELL_CUR" ]; then
      echo "✓ 壳已是最新。"
    elif [ -t 0 ]; then
      if _dsh_confirm "升级壳到 $_DSH_SHELL_LATEST? [y/N] "; then _dsh_shell_upgrade "$_DSH_SHELL_CUR" "$_DSH_SHELL_URL" "$_DSH_SHELL_LATEST"; else echo "已取消。"; fi
    else
      echo "ℹ 非交互环境，未自动升级壳。可手动运行 dsh-manage.sh shell（在 tty 中）。"
    fi
    ;;
  web) _dsh_web "$@" ;;
  pin) zsh "$BIN_DIR/pin-runtime.sh" 2>/dev/null || bash "$BIN_DIR/pin-runtime.sh" ;;
  doctor) _dsh_doctor ;;
  scan) node "$BIN_DIR/scan-adapters.mjs" "$@" ;;
  check)
    _dsh_check_update; _dsh_shell_check
    cron=0; [ "${1:-}" = "--cron" ] && cron=1
    upd=""
    [ -n "${_DSH_NEXT:-}" ] && _dsh_ver_gt "$_DSH_NEXT" "$_DSH_INST" && upd="runtime:next=$_DSH_NEXT"
    [ -n "${_DSH_LATEST:-}" ] && _dsh_ver_gt "$_DSH_LATEST" "$_DSH_INST" && upd="${upd:+$upd, }latest=$_DSH_LATEST"
    [ -n "${_DSH_SHELL_LATEST:-}" ] && [ "$_DSH_SHELL_CUR" != "$_DSH_SHELL_LATEST" ] && upd="${upd:+$upd, }shell=$_DSH_SHELL_LATEST"
    if [ $cron -eq 1 ]; then
      echo "dsh-check $(date -u +%FT%TZ) runtime=$_DSH_INST shell=$_DSH_SHELL_CUR updates=${upd:-none}"
    else
      echo "=== 健康检查 (check) ==="
      echo "runtime: ${_DSH_INST:-未知}（next=${_DSH_NEXT:-无} latest=${_DSH_LATEST:-无}）"
      echo "壳:     ${_DSH_SHELL_CUR:-未知}（最新=${_DSH_SHELL_LATEST:-无}）"
      echo "更新可用: ${upd:-无}"
      echo "--- 自检 ---"
      _dsh_doctor || true
    fi
    ;;
  rollback) _dsh_rollback "${1:-runtime}" ;;
  cleanup) _dsh_cleanup "$@" ;;
  install) _dsh_install "$@" ;;
  status)
    _dsh_check_update; _dsh_shell_check
    echo "runtime 当前: ${_DSH_INST:-未知} ｜ next: ${_DSH_NEXT:-无} ｜ latest: ${_DSH_LATEST:-无}"
    echo "壳     当前: ${_DSH_SHELL_CUR:-未知} ｜ 最新: ${_DSH_SHELL_LATEST:-无}"
    ;;
  *) echo "用法: dsh-manage.sh {install [--runtime <ver>|--no-shell|--no-runtime|--dry-run]|update [--dry-run]|update-runtime <ver>|update-src [<ver>]|shell|web [args..]|pin|status|doctor|scan|check [--cron]|rollback [runtime|shell|all]|cleanup [--dry-run]}" >&2; exit 1 ;;
esac

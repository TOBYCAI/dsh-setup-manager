#!/usr/bin/env node
// scan-plugin-api.mjs — 启动前的插件 API 兼容性静态预检。
//
// 背景：runtime 升级（如 0.1.1-rc.2 → 0.1.2-alpha.3）可能移除/改名 @deepseek-ai/* 包的
// 命名导出。插件若仍 import 已移除的符号，Node 在加载插件树时抛
// `SyntaxError: The requested module '...' does not provide an export named '...'`，
// 导致整个 profile 起不来——而崩溃发生在启动「之后」，用户只能看到报错栈。
// 本脚本在启动「之前」用静态解析比对「插件 import 的符号」与「runtime 实际导出的符号」，
// 提前列出冲突插件，把故障从「崩溃后排查」变成「启动前提示」。
//
// 与 scan-adapters.mjs 的分工：
//   scan-adapters.mjs   查「声明的版本范围」与 runtime 版本是否匹配（依赖声明层面）
//   本脚本             查「实际 import 的符号」在 runtime 中是否存在（代码层面）
//   二者互补：版本范围满足 ≠ API 兼容（alpha 轨道的破坏性重构往往不改 peerDep 范围）。
//
// 冲突分级（关键设计）：
//   「启用中」的插件冲突会导致启动崩溃 → 退出码 1，dsm web 会阻止启动
//   「未启用」的插件（已安装但不在 profile 依赖表）当前不会加载 → 仅提示，不阻止
//   不做分级的话，历史残留插件会淹没真正的告警，导致用户忽视所有输出。
//
// 用法：
//   node scan-plugin-api.mjs [--dsh-home <dir>] [--quiet] [--json]
//     --quiet  仅在检出「会导致崩溃」的冲突时输出（供 dsm web 启动前静默预检）
//     --json   机器可读输出（供脚本集成）
//
// 退出码：
//   0 = 无会导致启动崩溃的冲突
//   1 = 检出启用中插件的冲突（该冲突会导致 dsh web 启动崩溃）
//   2 = 环境不满足（无 node / 无 runtime 目录），视为跳过而非失败

import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { join, dirname, relative, isAbsolute } from 'node:path';
import { pathToFileURL } from 'node:url';

// ---------- 参数 ----------
function parseArgs(argv) {
  const out = { home: null, quiet: false, json: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--dsh-home') out.home = argv[++i];
    else if (a === '--quiet') out.quiet = true;
    else if (a === '--json') out.json = true;
  }
  return out;
}

// ---------- 静态解析：一个 ESM 文件的导出集合 ----------
// 只解析语法层面，不执行代码（零副作用，可在启动前安全运行）。
// 无法解析时返回 null（由调用方区分「解析失败」与「确实没有该导出」，避免误报）。
export function parseExports(file, seen = new Set()) {
  if (!file || !existsSync(file) || seen.has(file)) return null;
  seen.add(file);
  let src;
  try { src = readFileSync(file, 'utf8'); } catch { return null; }
  const out = new Set();
  // export { a, b as c, default as d }
  for (const m of src.matchAll(/export\s*\{([^}]*)\}/g)) {
    for (const part of m[1].split(',')) {
      const t = part.trim();
      if (!t) continue;
      const as = t.split(/\s+as\s+/);
      // 只取最终对外暴露的名字（export { x as y } 对外是 y）
      out.add((as[1] || as[0]).trim());
    }
  }
  // export const/let/var/function/class/async function
  for (const m of src.matchAll(/export\s+(?:async\s+)?(?:const|let|var|function\*?|class)\s+([A-Za-z_$][\w$]*)/g)) {
    out.add(m[1]);
  }
  // export default
  if (/export\s+default/.test(src)) out.add('default');
  // export * from './x'（仅跟随相对路径；外部包交给入口定位处理）
  for (const m of src.matchAll(/export\s*\*\s*from\s*['"](\.[^'"]+)['"]/g)) {
    let p = m[1];
    if (!/\.(js|mjs|cjs)$/.test(p)) p += '.js';
    const sub = parseExports(join(dirname(file), p), seen);
    if (sub) for (const e of sub) out.add(e);
  }
  return out;
}

// ---------- 定位 runtime 包的入口文件 ----------
// 优先级：exports["."]（含 import/default/node 条件）> main > module > lib/index.js
// 定位失败返回 { ok: false }——调用方须标记为「未解析」而非「冲突」，否则会误报。
export function entryOf(pkgName, runtimeNodeModules) {
  const pj = join(runtimeNodeModules, pkgName, 'package.json');
  if (!existsSync(pj)) return { ok: false, why: 'runtime 中不存在该包' };
  let j;
  try { j = JSON.parse(readFileSync(pj, 'utf8')); } catch { return { ok: false, why: 'package.json 解析失败' }; }
  let e = j.exports;
  if (e && typeof e === 'object' && !Array.isArray(e)) e = e['.'] ?? e.import ?? e.default ?? e.node;
  if (e && typeof e === 'object' && !Array.isArray(e)) e = e.import ?? e.default ?? e.node;
  const cand = [e, j.main, j.module, 'lib/index.js'].filter((x) => typeof x === 'string' && x);
  for (const c of cand) {
    const full = join(runtimeNodeModules, pkgName, c);
    try {
      if (existsSync(full) && statSync(full).isFile()) return { ok: true, file: full, via: c };
    } catch { /* 软链断裂等，继续尝试下一个候选 */ }
  }
  return { ok: false, why: `无可用入口（已试 ${cand.join(', ')}）` };
}

// ---------- 提取插件对 @deepseek-ai/* 的导入 ----------
// 覆盖：import { a, b as c } / import D / import D, { a } / import * as N（namespace 不校验具体符号）
const IMPORT_RE =
  /import\s+(?:(\w+)\s*,\s*)?(?:\{([^}]*)\}|\*\s+as\s+\w+|(\w+))\s+from\s+['"]([^'"]+)['"]/g;

export function extractImports(src, file) {
  const out = [];
  for (const m of src.matchAll(IMPORT_RE)) {
    const [, defMixed, named, defOnly, spec] = m;
    if (!spec.startsWith('@deepseek-ai/')) continue;
    const names = [];
    if (named) {
      for (const part of named.split(',')) {
        const t = part.trim();
        if (!t) continue;
        // import { a as b }：需要校验的是「原名字 a」，别名 b 只是本地叫法
        names.push(t.split(/\s+as\s+/)[0].trim());
      }
    }
    if (defMixed || defOnly) names.push('default');
    out.push({ spec, names, file });
  }
  return out;
}

// ---------- 收集目录下的 js 文件 ----------
export function jsFiles(dir, acc = [], depth = 0) {
  if (depth > 5 || !existsSync(dir)) return acc;
  let ents;
  try { ents = readdirSync(dir, { withFileTypes: true }); } catch { return acc; }
  for (const ent of ents) {
    if (ent.name === 'node_modules' || ent.name.startsWith('.')) continue;
    const full = join(dir, ent.name);
    try {
      // 用 statSync（跟随软链）而非 ent.isDirectory()：后者对 symlink 返回 false，
      // 会漏掉以软链形式存在的子目录。
      const st = statSync(full);
      if (st.isDirectory()) jsFiles(full, acc, depth + 1);
      else if (/\.(js|mjs|jsx)$/.test(ent.name)) acc.push(full);
    } catch { /* 权限/软链断裂，跳过 */ }
  }
  return acc;
}

// ---------- 识别真正的 dsh 插件 ----------
// 判据（满足其一）：目录下有 cordis.patch.yml，或 package.json 含 dsh 字段。
// 目的：把扫描范围从 node_modules 下所有包（含大量依赖）收窄到真正的插件。
export function isDshPlugin(dir) {
  if (existsSync(join(dir, 'cordis.patch.yml'))) return true;
  const pj = join(dir, 'package.json');
  if (!existsSync(pj)) return false;
  try {
    const j = JSON.parse(readFileSync(pj, 'utf8'));
    return Object.keys(j).some((k) => k.toLowerCase() === 'dsh');
  } catch { return false; }
}

// ---------- 读取 profile 声明的依赖（= 会被加载的插件）----------
function declaredDeps(pjPath) {
  if (!existsSync(pjPath)) return null;
  try {
    const j = JSON.parse(readFileSync(pjPath, 'utf8'));
    return new Set([...Object.keys(j.dependencies || {}), ...Object.keys(j.devDependencies || {})]);
  } catch { return null; }
}

// ---------- 收集待扫描的插件 ----------
// 每个插件记录 enabled：
//   true  = 在所属 profile 的 package.json 依赖表中（会被加载，冲突会导致崩溃）
//   false = 已安装但不在依赖表中（当前不会加载，多为历史残留）
//   null  = 无从判断（顶层 profiles/node_modules，未挂载到具体 profile）
export function collectPlugins(profilesDir) {
  const out = [];
  if (!existsSync(profilesDir)) return out;

  const collectFrom = (nmDir, profileName, declared) => {
    let pkgs = [];
    try { pkgs = readdirSync(nmDir, { withFileTypes: true }); } catch { return; }
    for (const p of pkgs) {
      // 跳过 scope 目录（@deepseek-ai 等是 runtime/依赖，不是插件）、点目录、.pnpm
      if (p.name.startsWith('.') || p.name.startsWith('@')) continue;
      const dir = join(nmDir, p.name);
      let st;
      try { st = statSync(dir); } catch { continue; }
      if (!st.isDirectory()) continue;
      if (!isDshPlugin(dir)) continue;
      out.push({
        name: p.name,
        dir,
        profile: profileName,
        enabled: declared ? declared.has(p.name) : null,
      });
    }
  };

  let ents = [];
  try { ents = readdirSync(profilesDir, { withFileTypes: true }); } catch { ents = []; }
  for (const e of ents) {
    if (e.name.startsWith('.') || e.name === 'node_modules') continue;
    const profDir = join(profilesDir, e.name);
    // statSync 跟随软链：profile 目录本身也可能是 link
    try { if (!statSync(profDir).isDirectory()) continue; } catch { continue; }
    const nmDir = join(profDir, 'node_modules');
    if (!existsSync(nmDir)) continue;
    collectFrom(nmDir, e.name, declaredDeps(join(profDir, 'package.json')));
  }
  // 顶层 profiles/node_modules：无对应 package.json，启用状态未知（多为历史残留）
  const topNM = join(profilesDir, 'node_modules');
  if (existsSync(topNM)) collectFrom(topNM, '(顶层)', null);
  return out;
}

// ---------- 核心检测 ----------
export function checkCompat({ home }) {
  const runtimeNM = join(home, 'runtime/node_modules');
  const profilesDir = join(home, 'profiles');
  const result = {
    runtimeVersion: null,
    pluginCount: 0,
    fileCount: 0,
    specs: {},         // spec -> { ok, count|why, via, exports }
    missing: [],       // 确定缺失，含 enabled 分级
    unresolved: [],    // 无法解析（非确定冲突，需人工确认）
    envOk: true,
  };

  const verFile = join(runtimeNM, '@deepseek-ai/dsh/package.json');
  if (existsSync(verFile)) {
    try { result.runtimeVersion = JSON.parse(readFileSync(verFile, 'utf8')).version; } catch { /* 忽略 */ }
  }
  if (!existsSync(runtimeNM)) { result.envOk = false; return result; }

  const plugins = collectPlugins(profilesDir);
  result.pluginCount = plugins.length;

  const cache = new Map();
  for (const plug of plugins) {
    for (const f of jsFiles(plug.dir)) {
      result.fileCount++;
      let src;
      try { src = readFileSync(f, 'utf8'); } catch { continue; }
      for (const imp of extractImports(src, f)) {
        if (!cache.has(imp.spec)) {
          const ent = entryOf(imp.spec, runtimeNM);
          cache.set(
            imp.spec,
            ent.ok
              ? { ok: true, exports: parseExports(ent.file), via: ent.via, file: ent.file }
              : { ok: false, why: ent.why }
          );
        }
        const c = cache.get(imp.spec);
        if (!c.ok) {
          result.unresolved.push({ plugin: plug.name, profile: plug.profile, enabled: plug.enabled, spec: imp.spec, why: c.why, file: f });
          continue;
        }
        for (const n of imp.names) {
          if (!c.exports.has(n)) {
            result.missing.push({
              plugin: plug.name,
              profile: plug.profile,
              enabled: plug.enabled,
              spec: imp.spec,
              name: n,
              file: f,
              have: [...c.exports].sort(),
            });
          }
        }
      }
    }
  }
  for (const [spec, c] of cache) {
    result.specs[spec] = c.ok
      ? { ok: true, count: c.exports.size, via: c.via, exports: [...c.exports].sort() }
      : { ok: false, why: c.why };
  }
  return result;
}

// ---------- 输出 ----------
function fmt(s, w) {
  const len = [...String(s)].length;
  return String(s) + ' '.repeat(Math.max(0, w - len));
}

// 会导致启动崩溃的：enabled === true（在 profile 依赖表中，启动时会被加载）
export function blockingConflicts(r) {
  return r.missing.filter((m) => m.enabled === true);
}
// 当前不会加载的：enabled === false 或 null（已装但未启用 / 无法判断）
export function latentConflicts(r) {
  return r.missing.filter((m) => m.enabled !== true);
}

function renderConflict(m) {
  return [
    `  ${m.plugin}（profile: ${m.profile}）：`,
    `    import { ${m.name} } from '${m.spec}'`,
    `    位置: ${m.file}`,
    `    该包实际导出: ${m.have.join(', ') || '(无)'}`,
  ].join('\n');
}

function renderText(r) {
  const blocking = blockingConflicts(r);
  const latent = latentConflicts(r);
  const lines = [];

  lines.push('=== 插件 API 兼容性检查 ===');
  lines.push(`runtime: ${r.runtimeVersion || '未知'} ｜ 已识别插件: ${r.pluginCount} 个 ｜ 扫描文件: ${r.fileCount} 个`);

  const specKeys = Object.keys(r.specs);
  if (specKeys.length) {
    lines.push('');
    lines.push(fmt('插件 import 的 runtime 包', 40) + fmt('状态', 12) + '导出数');
    for (const spec of specKeys.sort()) {
      const c = r.specs[spec];
      lines.push(fmt(spec, 40) + fmt(c.ok ? '✅ 可解析' : '⚠️  未解析', 12) + (c.ok ? String(c.count) : c.why));
    }
  }

  if (blocking.length) {
    lines.push('');
    lines.push(`❌ 检出 ${blocking.length} 处冲突（插件已启用，会导致 dsh web 启动崩溃）:`);
    for (const m of blocking) { lines.push(''); lines.push(renderConflict(m)); }
    lines.push('');
    lines.push('建议（任选其一）：');
    lines.push('  1. 升级冲突插件到适配当前 runtime 的版本（alpha 轨道需装预发布版，latest 未必跟上）');
    lines.push('  2. dsm rollback runtime 回到升级前的 runtime 版本');
    lines.push('  3. 确认该插件不会被加载后，用 dsm web --force 强制启动');
  }

  if (latent.length) {
    lines.push('');
    lines.push(`⚠️  ${latent.length} 处冲突位于「未启用」的插件（当前不会加载，不影响启动）:`);
    for (const m of latent) { lines.push(''); lines.push(renderConflict(m)); }
    lines.push('');
    lines.push('  说明：这些插件已安装但不在 profile 的依赖表中，启动时不会被 import。');
    lines.push('  若日后启用它们（加入 profile 依赖），同样会触发崩溃——届时需先升级到适配版本。');
  }

  if (r.unresolved.length) {
    lines.push('');
    lines.push(`⚠️  ${r.unresolved.length} 处无法解析（非确定冲突，需人工确认）:`);
    const seen = new Set();
    for (const u of r.unresolved) {
      const key = `${u.plugin}|${u.spec}`;
      if (seen.has(key)) continue;
      seen.add(key);
      lines.push(`  ${u.plugin} -> ${u.spec}：${u.why}`);
    }
  }

  if (!blocking.length && !latent.length && !r.unresolved.length) {
    lines.push('');
    lines.push('✅ 未发现冲突：所有插件 import 的符号在当前 runtime 中均存在。');
  } else if (!blocking.length) {
    lines.push('');
    lines.push('✅ 无会导致启动崩溃的冲突（上文的未启用冲突不影响本次启动）。');
  }
  return lines.join('\n');
}

// ---------- 主入口 ----------
function main() {
  const args = parseArgs(process.argv.slice(2));
  const homeArg = args.home || process.env.DSH_HOME || join(process.env.HOME || '~', '.dsh');
  const home = isAbsolute(homeArg) ? homeArg : join(process.cwd(), homeArg);

  const r = checkCompat({ home });

  if (!r.envOk) {
    if (!args.quiet) {
      console.error(`⚠ 未找到 runtime 目录（${join(home, 'runtime/node_modules')}），跳过插件 API 检查。`);
    }
    process.exit(2);
  }

  const blocking = blockingConflicts(r);
  if (args.json) {
    console.log(JSON.stringify(r, null, 2));
  } else if (args.quiet) {
    // 静默模式：仅在有「会导致崩溃」的冲突时输出，避免干扰正常启动日志
    if (blocking.length) console.error(renderText(r));
  } else {
    console.log(renderText(r));
  }

  process.exit(blocking.length ? 1 : 0);
}

// 仅当作为脚本直接运行时执行 main（被 import 做单元测试时不执行）
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main();
}

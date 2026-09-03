#!/usr/bin/env node
// check-desktop.mjs — DSH Desktop 与共享 runtime 的兼容性静态预检。
//
// 背景：Desktop 与 CLI 共享 ~/.dsh/runtime（app.asar.unpacked 内是软链视图）。
// runtime 升级后可能出两类「dsm check 旧版发现不了」的启动故障：
//   第 1 层（清单缺口）：app.asar 的 header 清单是打包时的包名快照，runtime 新增的包
//     不在清单里 → Electron 从 asar 路径解析模块时直接 ENOENT
//     （ERR_MODULE_NOT_FOUND），主进程启动即崩。真实磁盘上有软链也没用——
//     asar 虚拟层只认 header 清单。
//   第 2 层（API 代差）：Desktop 应用代码（asar 内 lib/*.js）import 的命名导出
//     可能在新版 runtime 中已被移除/改名（如 0.1.2 轨道 dsh-settings 移除
//     settingsNamespace）→ `SyntaxError: The requested module ... does not
//     provide an export named ...`。
// 本脚本在「启动前 / runtime 升级前后」静态比对，把故障提前暴露：
//   ① 解析 app.asar header 清单，比对 @deepseek-ai 包名集合 vs runtime（缺口=警告）
//   ② 扫描 Desktop 应用代码对 @deepseek-ai/* 的命名导入，比对 runtime 实际导出
//     （缺失=致命冲突，退出码 1——该冲突会导致主进程崩溃）
//
// 与 scan-plugin-api.mjs 的分工：
//   scan-plugin-api.mjs  查「插件」与 runtime 的 API 兼容性（profile 侧）
//   本脚本              查「Desktop 应用本体」与 runtime 的兼容性（app 侧）
//   复用前者的 parseExports / entryOf / extractImports（同一套静态解析语义）。
//
// 用法：
//   node check-desktop.mjs [--app <DSH Desktop.app 路径>] [--dsh-home <dir>] [--quiet] [--json]
//     --quiet  仅在检出致命冲突时输出
//     --json   机器可读输出
//
// 退出码：
//   0 = 兼容（或未安装 Desktop，视为跳过）
//   1 = 检出致命冲突（应用代码 import 的符号在 runtime 中缺失，启动会崩）
//   2 = 环境不满足（有 Desktop 但 asar/运行时无法解析），视为跳过而非失败

import { existsSync, readFileSync, readdirSync, statSync, openSync, readSync, closeSync, fstatSync } from 'node:fs';
import { join, dirname, isAbsolute } from 'node:path';
import { pathToFileURL } from 'node:url';
import { parseExports, entryOf, extractImports } from './scan-plugin-api.mjs';

// ---------- 参数 ----------
function parseArgs(argv) {
  const out = { app: null, home: null, quiet: false, json: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--app') out.app = argv[++i];
    else if (a === '--dsh-home') out.home = argv[++i];
    else if (a === '--quiet') out.quiet = true;
    else if (a === '--json') out.json = true;
  }
  return out;
}

// ---------- asar header 解析 ----------
// 实测布局（DSH Desktop v2.0.4 的 app.asar，Electron asar pickle 嵌套）：
//   u32@0 = 4、u32@4 = u32@12 + 8、u32@8 = u32@12 + 4、u32@12 = JSON 长度，
//   JSON 从 offset 16 开始（DSH 的 asar 是「纯清单」结构，JSON 本身可达数 MB，
//   文件总长 = 16 + JSON 长度 + 少量对齐 padding）。
// 以 u32@0 是否为 4 + 「16+JSON 长度 ≈ 文件总长」做哨兵，异常即判不可解析。
export function parseAsarHeader(asarPath) {
  let fd;
  try { fd = openSync(asarPath, 'r'); } catch { return { ok: false, why: '无法打开 asar 文件' }; }
  try {
    const size = fstatSync(fd).size;
    const head = Buffer.alloc(16);
    readSync(fd, head, 0, 16, 0);
    if (head.readUInt32LE(0) !== 4) return { ok: false, why: '不是预期的 asar pickle 布局' };
    const jsonLen = head.readUInt32LE(12);
    const tail = size - 16 - jsonLen;
    if (jsonLen <= 2 || tail < 0 || tail > 3) {
      return { ok: false, why: `header JSON 长度与文件总长不符（jsonLen=${jsonLen}, size=${size}）` };
    }
    const jsonBuf = Buffer.alloc(jsonLen);
    const n = readSync(fd, jsonBuf, 0, jsonLen, 16);
    if (n !== jsonLen) return { ok: false, why: 'header JSON 读取不完整' };
    return { ok: true, manifest: JSON.parse(jsonBuf.toString('utf8')) };
  } catch (e) {
    return { ok: false, why: `header 解析失败：${e.message}` };
  } finally {
    try { closeSync(fd); } catch { /* 忽略 */ }
  }
}

// 从 asar manifest 取 node_modules/@deepseek-ai 下的包名集合。
// 兼容两种布局：node_modules 在根（实测如此），或包在 app/ 子目录下。
export function manifestPkgs(manifest) {
  const roots = [];
  const top = manifest?.files || {};
  if (top['node_modules']?.files) roots.push(top['node_modules'].files);
  if (top['app']?.files?.['node_modules']?.files) roots.push(top['app'].files['node_modules'].files);
  for (const r of roots) {
    const scope = r['@deepseek-ai']?.files;
    if (scope) return Object.keys(scope);
  }
  return null; // 清单里找不到 @deepseek-ai scope（区别于空数组）
}

// ---------- Desktop 应用代码定位 ----------
// 应用自有代码在 app.asar.unpacked 下（本 asar 是「纯清单」结构，无内嵌 body），
// 排除 node_modules（那是 runtime 软链视图，插件扫描已覆盖等价物）。
export function appCodeFiles(unpackedDir, acc = [], depth = 0) {
  if (depth > 3 || !existsSync(unpackedDir)) return acc;
  let ents;
  try { ents = readdirSync(unpackedDir, { withFileTypes: true }); } catch { return acc; }
  for (const ent of ents) {
    if (ent.name === 'node_modules' || ent.name.startsWith('.')) continue;
    const full = join(unpackedDir, ent.name);
    let st;
    try { st = statSync(full); } catch { continue; }
    if (st.isDirectory()) appCodeFiles(full, acc, depth + 1);
    else if (/\.(js|mjs)$/.test(ent.name)) acc.push(full);
  }
  return acc;
}

// 从 Info.plist 提取 Desktop 版本（xml/binary plist 都尝试 ascii 正则，失败不致命）
export function desktopVersion(appPath) {
  const plist = join(appPath, 'Contents', 'Info.plist');
  if (!existsSync(plist)) return null;
  try {
    const raw = readFileSync(plist, 'utf8');
    const m = raw.match(/CFBundleShortVersionString[\s\S]{0,80}?([0-9]+\.[0-9]+(?:[.][0-9A-Za-z]+)*)/);
    return m ? m[1] : null;
  } catch { return null; }
}

// ---------- 核心检测 ----------
export function checkDesktop({ appPath, home }) {
  const result = {
    appPath,
    desktopVersion: null,
    asarFound: false,
    runtimeVersion: null,
    manifestCount: 0,
    runtimeCount: 0,
    manifestOnly: [],   // 清单有、runtime 没有（rc 升级后被删的包；无实体，一般无害）
    runtimeOnly: [],    // runtime 有、清单没有 → asar 路径解析会 ENOENT（若被 import 即崩）
    fileCount: 0,
    specs: {},          // spec -> { ok, count|why }
    conflicts: [],      // 确定冲突：import 的命名导出在 runtime 中不存在（致命）
    unresolved: [],     // 无法解析（非确定冲突，需人工确认）
    envOk: true,
    why: null,
  };
  if (!appPath) { result.envOk = false; result.why = '未安装 Desktop'; return result; }
  result.desktopVersion = desktopVersion(appPath);

  const asar = join(appPath, 'Contents', 'Resources', 'app.asar');
  const unpacked = join(appPath, 'Contents', 'Resources', 'app.asar.unpacked');
  const runtimeNM = join(home, 'runtime/node_modules');
  result.asarFound = existsSync(asar);
  if (!existsSync(runtimeNM)) { result.envOk = false; result.why = '未找到 runtime 目录'; return result; }
  const verFile = join(runtimeNM, '@deepseek-ai/dsh/package.json');
  if (existsSync(verFile)) {
    try { result.runtimeVersion = JSON.parse(readFileSync(verFile, 'utf8')).version; } catch { /* 忽略 */ }
  }

  // 第 1 层：清单 vs runtime 包名差集
  if (result.asarFound) {
    const h = parseAsarHeader(asar);
    if (!h.ok) {
      result.envOk = false; result.why = h.why; return result;
    }
    const pkgs = manifestPkgs(h.manifest);
    if (pkgs === null) {
      result.envOk = false; result.why = 'asar 清单中未找到 node_modules/@deepseek-ai'; return result;
    }
    let runtimeList = [];
    try { runtimeList = readdirSync(join(runtimeNM, '@deepseek-ai')); } catch { /* 忽略 */ }
    const mSet = new Set(pkgs);
    const rSet = new Set(runtimeList);
    result.manifestCount = pkgs.length;
    result.runtimeCount = runtimeList.length;
    result.manifestOnly = [...mSet].filter((p) => !rSet.has(p)).sort();
    result.runtimeOnly = [...rSet].filter((p) => !mSet.has(p)).sort();
  }

  // 第 2 层：应用代码 import 的命名导出 vs runtime 实际导出
  if (existsSync(unpacked)) {
    const cache = new Map();
    for (const f of appCodeFiles(unpacked)) {
      result.fileCount++;
      let src;
      try { src = readFileSync(f, 'utf8'); } catch { continue; }
      for (const imp of extractImports(src, f)) {
        if (!cache.has(imp.spec)) {
          const ent = entryOf(imp.spec, runtimeNM);
          cache.set(
            imp.spec,
            ent.ok
              ? { ok: true, exports: parseExports(ent.file), via: ent.via }
              : { ok: false, why: ent.why }
          );
        }
        const c = cache.get(imp.spec);
        if (!c.ok) {
          result.unresolved.push({ spec: imp.spec, name: imp.names[0] || '', why: c.why, file: f });
          continue;
        }
        for (const n of imp.names) {
          if (!c.exports.has(n)) {
            result.conflicts.push({ spec: imp.spec, name: n, file: f, have: [...c.exports].sort() });
          }
        }
      }
    }
    for (const [spec, c] of cache) {
      result.specs[spec] = c.ok
        ? { ok: true, count: c.exports.size, via: c.via }
        : { ok: false, why: c.why };
    }
  }
  return result;
}

// ---------- 输出 ----------
function renderText(r) {
  const lines = [];
  lines.push('=== Desktop 兼容性检查 ===');
  lines.push(`Desktop: ${r.appPath}${r.desktopVersion ? `（v${r.desktopVersion}）` : ''}`);
  lines.push(`runtime: ${r.runtimeVersion || '未知'}`);
  if (!r.envOk) {
    lines.push(`⚠️  跳过：${r.why}`);
    return lines.join('\n');
  }

  if (r.manifestOnly.length || r.runtimeOnly.length) {
    lines.push('');
    lines.push(`asar 清单 ${r.manifestCount} 包 ｜ runtime ${r.runtimeCount} 包`);
    if (r.runtimeOnly.length) {
      lines.push(`⚠️  runtime 有而 asar 清单没有（${r.runtimeOnly.length} 个）：${r.runtimeOnly.join(', ')}`);
      lines.push('    这些包从 asar 路径解析会 ENOENT；若 Desktop 应用代码 import 了它们，启动即崩。');
    }
    if (r.manifestOnly.length) {
      lines.push(`ℹ️  asar 清单有而 runtime 没有（${r.manifestOnly.length} 个，无实体，一般无害）：${r.manifestOnly.join(', ')}`);
    }
  } else {
    lines.push('');
    lines.push(`✅ asar 清单与 runtime 包名集合一致（${r.manifestCount} 包）。`);
  }

  const specKeys = Object.keys(r.specs);
  if (specKeys.length) {
    lines.push('');
    lines.push(`应用代码 import 的 runtime 包（扫描文件 ${r.fileCount} 个）:`);
    for (const spec of specKeys.sort()) {
      const c = r.specs[spec];
      lines.push(`  ${spec}: ${c.ok ? `✅ 可解析（导出 ${c.count} 个）` : `⚠️  未解析（${c.why}）`}`);
    }
  }

  if (r.conflicts.length) {
    lines.push('');
    lines.push(`❌ 检出 ${r.conflicts.length} 处致命冲突（Desktop 主进程加载即崩）:`);
    const seen = new Set();
    for (const c of r.conflicts) {
      lines.push(`  import { ${c.name} } from '${c.spec}'`);
      lines.push(`    位置: ${c.file}`);
      lines.push(`    runtime 实际导出: ${c.have.join(', ') || '(无)'}`);
    }
    lines.push('');
    lines.push('建议（任选其一）：');
    lines.push('  1. 等 Desktop 官方发布适配当前 runtime 基线的新版本后升级 Desktop');
    lines.push('  2. dsm rollback runtime 回到与 Desktop 打包基线一致的版本');
    lines.push('  3. 升级 runtime 前先跑 dsm check 预判（本检查）');
  } else if (r.unresolved.length) {
    const uniq = [...new Set(r.unresolved.map((u) => `${u.spec}: ${u.why}`))];
    lines.push('');
    lines.push(`⚠️  ${uniq.length} 个包无法静态解析（非确定冲突，需人工确认）:`);
    for (const u of uniq) lines.push(`  ${u}`);
  } else {
    lines.push('');
    lines.push('✅ 应用代码 import 的符号在当前 runtime 中均存在，主进程可加载。');
  }
  return lines.join('\n');
}

// ---------- 主入口 ----------
function main() {
  const args = parseArgs(process.argv.slice(2));
  const homeArg = args.home || process.env.DSH_HOME || join(process.env.HOME || '~', '.dsh');
  const home = isAbsolute(homeArg) ? homeArg : join(process.cwd(), homeArg);

  const candidates = args.app
    ? [args.app]
    : [join('/Applications', 'DSH Desktop.app'), join(process.env.HOME || '~', 'Applications', 'DSH Desktop.app')];
  const appPath = candidates.find((p) => existsSync(p)) || null;

  const r = checkDesktop({ appPath, home });

  const critical = r.conflicts.length > 0;
  if (args.json) {
    console.log(JSON.stringify(r, null, 2));
  } else if (args.quiet) {
    if (critical) console.error(renderText(r));
  } else {
    console.log(renderText(r));
  }
  process.exit(critical ? 1 : r.envOk ? 0 : 2);
}

// 仅当作为脚本直接运行时执行 main（被 import 做单元测试时不执行）
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main();
}

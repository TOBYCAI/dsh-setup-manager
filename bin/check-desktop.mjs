#!/usr/bin/env node
// check-desktop.mjs — DSH Desktop 与 runtime 的兼容性静态预检。
//
// Desktop 的打包模式**随版本变化**，两种模式的故障面完全不同（2026-09-10 实测）：
//
//   模式 A「共享软链」（≤ v2.0.5）
//     app.asar 是**纯清单**：正文几乎为空，`node_modules/@deepseek-ai/*` 解包到
//     app.asar.unpacked 并软链到 `~/.dsh/runtime`（由 pin-runtime.sh 改写）。
//     壳与 CLI 共用同一份 runtime，因此会出现：
//       · 第 1 层（清单缺口）——runtime 新增的包不在 asar 清单里，Electron 从 asar
//         路径解析模块时直接 ENOENT（磁盘上有软链也没用，asar 虚拟层只认清单）；
//       · 第 2 层（API 代差）——壳应用代码 import 的命名导出被新 runtime 移除/改名
//         （如 0.1.2 轨道移除 dsh-settings 的 settingsNamespace）。
//
//   模式 B「自包含」（≥ v2.0.7）
//     壳把整棵 `node_modules` 打进 asar 正文（实测 245 个 @deepseek-ai 包、正文
//     ~175 MB），unpacked 只剩 node-addon-system-* 两个真实目录，**不再有软链农场**。
//     壳携带自己的 runtime 副本（v2.0.7 内置 0.1.5-rc.1），与 CLI 的
//     `~/.dsh/runtime` 是**两份独立副本**：升级 CLI runtime 不会改变壳的行为，
//     壳也不会把 profile 链接拽走。此时的兼容性问题是**版本偏差**：
//       · 壳内置 dsh 与当前 runtime 版本不一致 → 两端行为/插件 API 面可能不同；
//       · 壳自带副本决定了它能兼容哪些插件，与 pin 住的 runtime 无关。
//
// 本脚本在「启动前 / runtime 升级前后」静态比对，把故障提前暴露：
//   ① 解析 app.asar（pickle 头部 + 正文偏移），得到包名清单与打包模式
//   ② 模式 A：比对 asar 清单 vs runtime 包名集合（缺口=警告）
//      模式 B：比对壳内置 dsh 版本 vs 当前 runtime 版本（偏差=警告）
//   ③ 扫描壳应用代码（模式 A 取自 unpacked，模式 B 从 asar 正文按条目偏移读出）
//      对 @deepseek-ai/* 的命名导入，比对 runtime 实际导出（缺失=致命冲突，退出码 1）
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
import { join, dirname, isAbsolute, relative } from 'node:path';
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

// ---------- asar 解析 ----------
// Electron asar = pickle 头部 + 正文（正文可空）：
//   u32@0 = 4、u32@4 = ceil4(jsonLen)+8、u32@8 = ceil4(jsonLen)+4、u32@12 = jsonLen，
//   JSON 从 offset 16 开始，正文起点 dataOffset = 16 + ceil4(jsonLen)。
// 文件条目 = { size, offset }（offset 相对 dataOffset；`unpacked: true` 表示实体在
// app.asar.unpacked 下）。
//
// **不要**再用「文件总长 ≈ 16 + jsonLen」当哨兵：那只是模式 A（纯清单）的巧合，
// 模式 B 的正文有上百 MB，会把好 asar 判成坏（2026-08-28 写的假设，2026-09-10
// 被 Desktop 2.0.7 打成「跳过」，等于整个预检失效）。
// 正确的最小校验：头部 pickle 形态成立 + JSON 能完整读出。
export function parseAsarHeader(asarPath) {
  let fd;
  try { fd = openSync(asarPath, 'r'); } catch { return { ok: false, why: '无法打开 asar 文件' }; }
  try {
    const size = fstatSync(fd).size;
    const head = Buffer.alloc(16);
    readSync(fd, head, 0, 16, 0);
    if (head.readUInt32LE(0) !== 4) return { ok: false, why: '不是预期的 asar pickle 布局' };
    const jsonLen = head.readUInt32LE(12);
    if (jsonLen <= 2 || 16 + jsonLen > size) {
      return { ok: false, why: `header JSON 长度与文件总长不符（jsonLen=${jsonLen}, size=${size}）` };
    }
    const jsonBuf = Buffer.alloc(jsonLen);
    const n = readSync(fd, jsonBuf, 0, jsonLen, 16);
    if (n !== jsonLen) return { ok: false, why: 'header JSON 读取不完整' };
    let manifest;
    try { manifest = JSON.parse(jsonBuf.toString('utf8')); } catch (e) {
      return { ok: false, why: `header JSON 解析失败：${e.message}` };
    }
    const dataOffset = 16 + ((jsonLen + 3) & ~3);
    return { ok: true, manifest, jsonLen, dataOffset, bodyBytes: Math.max(0, size - dataOffset), fileSize: size };
  } catch (e) {
    return { ok: false, why: `header 解析失败：${e.message}` };
  } finally {
    try { closeSync(fd); } catch { /* 忽略 */ }
  }
}

// 按 asar 路径取文件条目（目录条目返回 null）。
export function asarEntry(manifest, relPath) {
  const parts = String(relPath).split('/').filter(Boolean);
  let node = manifest && manifest.files;
  for (let i = 0; i < parts.length && node; i++) {
    node = node[parts[i]];
    if (node && i < parts.length - 1) node = node.files;
  }
  return node && !node.files ? node : null;
}

// 从 asar 读一个文件：unpacked 条目走 app.asar.unpacked，其余按 offset/size 从正文读。
// 返回 Buffer 或 null（缺失/越界/读取不完整）。
export function readAsarFile({ asarPath, unpackedDir, dataOffset, relPath, entry }) {
  if (!entry) return null;
  if (entry.unpacked) {
    const p = join(unpackedDir, relPath);
    try { return existsSync(p) ? readFileSync(p) : null; } catch { return null; }
  }
  const off = Number(entry.offset);
  const size = Number(entry.size);
  if (!Number.isFinite(off) || !Number.isFinite(size) || off < 0 || size < 0) return null;
  let fd;
  try { fd = openSync(asarPath, 'r'); } catch { return null; }
  try {
    const buf = Buffer.alloc(size);
    const got = readSync(fd, buf, 0, size, dataOffset + off);
    return got === size ? buf : null;
  } catch { return null; } finally {
    try { closeSync(fd); } catch { /* 忽略 */ }
  }
}

// 壳应用自有代码在清单里的相对路径（排除 node_modules 等第三方目录）。
export function asarAppCodePaths(manifest, exclude = new Set(['node_modules', 'build'])) {
  const out = [];
  const walk = (node, prefix, depth) => {
    if (!node || !node.files || depth > 4) return;
    for (const [name, child] of Object.entries(node.files)) {
      if (name.startsWith('.') || (depth === 0 && exclude.has(name))) continue;
      const rel = prefix ? `${prefix}/${name}` : name;
      if (child.files) walk(child, rel, depth + 1);
      else if (/\.(js|mjs|cjs)$/.test(name)) out.push(rel);
    }
  };
  walk(manifest, '', 0);
  return out;
}

// 打包模式判定（两条判据，任一成立即自包含）：
//   ① 壳内自带 dsh 是**打包条目**（清单里有 offset 且未标 unpacked）——
//      这是「壳携带自己的 runtime 副本」的直接证据，与 asar 体积无关；
//   ② 正文 > 1 MB —— 兜底，覆盖壳不带 @deepseek-ai/dsh 自己的极端布局。
// 只用体积当判据是不行的：小体积的自包含 asar（测试夹具、精简包）会被误判成共享。
export function desktopMode(header) {
  if (!header || !header.ok) return 'unknown';
  const e = asarEntry(header.manifest, 'node_modules/@deepseek-ai/dsh/package.json');
  const bundledPacked = !!(e && !e.unpacked && Number.isFinite(Number(e.offset)));
  if (bundledPacked) return 'packed';
  return header.bodyBytes > 1024 * 1024 ? 'packed' : 'shared';
}

// 壳内置的 dsh 版本：优先读 asar 内 node_modules/@deepseek-ai/dsh/package.json
// （模式 B 的真实自带副本），读不到再退回 unpacked 目录（模式 A 的软链视图，
// 那其实是 runtime 的版本，仅作兜底并在输出里以「未内置」区分）。
export function bundledDshVersion({ asarPath, unpackedDir, header }) {
  const rel = 'node_modules/@deepseek-ai/dsh/package.json';
  const read = (buf) => {
    if (!buf) return null;
    try { const j = JSON.parse(buf.toString('utf8')); return typeof j.version === 'string' ? j.version : null; } catch { return null; }
  };
  if (header && header.ok) {
    const fromAsar = read(readAsarFile({
      asarPath, unpackedDir, dataOffset: header.dataOffset, relPath: rel, entry: asarEntry(header.manifest, rel),
    }));
    if (fromAsar) return { version: fromAsar, from: 'asar' };
  }
  const p = join(unpackedDir, rel);
  try { if (existsSync(p)) return { version: read(readFileSync(p)), from: 'unpacked' }; } catch { /* 忽略 */ }
  return null;
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
// 模式 A（≤2.0.5）应用代码在 app.asar.unpacked/lib 下，直接走文件系统；
// 模式 B（≥2.0.7）lib/ 打包进 asar 正文，必须按清单条目偏移读出（见 collectAppCode）。
// 两种都排除 node_modules（第三方副本，插件扫描已覆盖等价物）。
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

// 汇总壳应用代码（供第 2 层 API 扫描）：清单优先（覆盖模式 B 的打包代码），
// unpacked 文件系统兜底 / 补充（覆盖模式 A）。返回 [{ label, text }]。
export function collectAppCode({ asarPath, unpackedDir, header }) {
  const seen = new Set();
  const files = [];
  const push = (rel, buf) => {
    if (!buf || seen.has(rel)) return;
    seen.add(rel);
    files.push({ label: `asar:${rel}`, text: buf.toString('utf8') });
  };
  if (header && header.ok) {
    for (const rel of asarAppCodePaths(header.manifest)) {
      push(rel, readAsarFile({
        asarPath, unpackedDir, dataOffset: header.dataOffset, relPath: rel, entry: asarEntry(header.manifest, rel),
      }));
    }
  }
  for (const full of appCodeFiles(unpackedDir)) {
    const rel = relative(unpackedDir, full);
    if (seen.has(rel)) continue;
    seen.add(rel);
    let text = null;
    try { text = readFileSync(full, 'utf8'); } catch { /* 忽略 */ }
    if (text !== null) files.push({ label: full, text });
  }
  return files;
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
    mode: 'unknown',        // 'packed'（≥2.0.7 自包含）| 'shared'（≤2.0.5 软链共享）
    bodyBytes: 0,           // asar 正文大小（模式 B 上百 MB，模式 A ≈0）
    runtimeVersion: null,   // CLI 侧 ~/.dsh/runtime 的 dsh 版本
    bundledVersion: null,   // 壳自带的 dsh 版本（模式 B 才有意义）
    bundledFrom: null,      // 'asar' | 'unpacked'
    manifestCount: 0,
    runtimeCount: 0,
    manifestOnly: [],   // 清单有、runtime 没有（rc 升级后被删的包；无实体，一般无害）
    runtimeOnly: [],    // runtime 有、清单没有 → asar 路径解析会 ENOENT（若被 import 即崩）
    fileCount: 0,
    specs: {},          // spec -> { ok, count|why }
    conflicts: [],      // 确定冲突：import 的命名导出在比对基准中不存在
    fatal: false,       // 冲突是否致命（壳与比对基准同源时才置真；见函数末尾的判定）
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

  // 头部解析 + 打包模式 + 壳内置版本
  let header = null;
  if (result.asarFound) {
    header = parseAsarHeader(asar);
    if (!header.ok) {
      result.envOk = false; result.why = header.why; return result;
    }
    result.mode = desktopMode(header);
    result.bodyBytes = header.bodyBytes;
    const bundled = bundledDshVersion({ asarPath: asar, unpackedDir: unpacked, header });
    if (bundled) { result.bundledVersion = bundled.version; result.bundledFrom = bundled.from; }
  }

  // 第 1 层（模式相关）：
  //   模式 A（共享软链）→ 清单 vs runtime 包名差集（新增包会让 asar 解析 ENOENT）
  //   模式 B（自包含）  → 壳自带副本 vs CLI runtime 的**版本偏差**（两份独立副本）
  if (header && header.ok) {
    const pkgs = manifestPkgs(header.manifest);
    if (pkgs === null) {
      result.envOk = false; result.why = 'asar 清单中未找到 node_modules/@deepseek-ai'; return result;
    }
    result.manifestCount = pkgs.length;
    if (result.mode === 'shared') {
      let runtimeList = [];
      try { runtimeList = readdirSync(join(runtimeNM, '@deepseek-ai')); } catch { /* 忽略 */ }
      const mSet = new Set(pkgs);
      const rSet = new Set(runtimeList);
      result.runtimeCount = runtimeList.length;
      result.manifestOnly = [...mSet].filter((p) => !rSet.has(p)).sort();
      result.runtimeOnly = [...rSet].filter((p) => !mSet.has(p)).sort();
    }
  }

  // 第 2 层：应用代码 import 的命名导出 vs runtime 实际导出
  // （应用代码可能打包在 asar 正文里——模式 B 必须从清单条目读，否则会扫到 0 个文件
  //   而报「全部兼容」的假绿）
  const appCode = collectAppCode({ asarPath: asar, unpackedDir: unpacked, header });
  if (appCode.length > 0) {
    const cache = new Map();
    for (const { label, text } of appCode) {
      result.fileCount++;
      for (const imp of extractImports(text, label)) {
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
          result.unresolved.push({ spec: imp.spec, name: imp.names[0] || '', why: c.why, file: label });
          continue;
        }
        for (const n of imp.names) {
          if (!c.exports.has(n)) {
            result.conflicts.push({ spec: imp.spec, name: n, file: label, have: [...c.exports].sort() });
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

  // 冲突定性：只有「壳与比对基准同源」时才算致命（退出码 1）——
  //   模式 A（共享软链）：壳就跑这份 runtime → 缺符号必崩
  //   模式 B（自包含）：仅当壳自带副本版本 === CLI runtime 版本，两端等价 → 缺符号必崩
  //   模式 B 且版本不一致：壳用自己的副本解析，拿 CLI runtime 当基准的差异仅供参考，
  //   置致命会误杀（这正是 2.0.7 之后必须区分的新语义）
  result.fatal = result.conflicts.length > 0
    && (result.mode === 'shared'
      || (!!result.bundledVersion && result.bundledVersion === result.runtimeVersion));
  return result;
}

// ---------- 输出 ----------
const mb = (n) => `${(n / 1024 / 1024).toFixed(1)} MB`;

function renderText(r) {
  const lines = [];
  lines.push('=== Desktop 兼容性检查 ===');
  lines.push(`Desktop: ${r.appPath}${r.desktopVersion ? `（v${r.desktopVersion}）` : ''}`);
  lines.push(`runtime（CLI）: ${r.runtimeVersion || '未知'}`);
  if (!r.envOk) {
    lines.push(`⚠️  跳过：${r.why}`);
    return lines.join('\n');
  }

  if (r.mode === 'packed') {
    lines.push(`打包模式: 自包含（壳自带 dsh 副本${r.bundledVersion ? ` ${r.bundledVersion}` : '（版本读不出）'}，asar 正文 ${mb(r.bodyBytes)}，清单 ${r.manifestCount} 个 @deepseek-ai 包）`);
    if (r.bundledVersion && r.runtimeVersion) {
      if (r.bundledVersion === r.runtimeVersion) {
        lines.push(`✅ 壳自带 dsh 与 CLI runtime 版本一致（${r.bundledVersion}）——两端行为基线相同。`);
      } else {
        lines.push(`⚠️  版本偏差：壳自带 ${r.bundledVersion} ≠ CLI runtime ${r.runtimeVersion}`);
        lines.push('    壳用自带副本运行，升级/回退 CLI runtime 不会改变壳的行为；两端插件 API 面可能不同。');
        lines.push('    要对齐：升级壳（dsm shell）拿到新基线，或把 runtime 退到壳的基线（dsm update-runtime <版本>）。');
      }
    } else if (!r.bundledVersion) {
      lines.push('ℹ️  未能读出壳自带 dsh 版本（清单中无 node_modules/@deepseek-ai/dsh/package.json）。');
    }
    lines.push('ℹ️  自包含模式下壳不再共享 ~/.dsh/runtime：无需（也不应）改写 .app 内的软链；dsm pin 只作用于 profiles。');
  } else if (r.mode === 'shared') {
    lines.push(`打包模式: 共享软链（asar 正文 ${mb(r.bodyBytes)}，壳经 app.asar.unpacked 软链使用 ~/.dsh/runtime）`);
    if (r.manifestOnly.length || r.runtimeOnly.length) {
      lines.push('');
      lines.push(`asar 清单 ${r.manifestCount} 包 ｜ runtime ${r.runtimeCount} 包`);
      if (r.runtimeOnly.length) {
        lines.push(`⚠️  runtime 有而 asar 清单没有（${r.runtimeOnly.length} 个）：${r.runtimeOnly.join(', ')}`);
        lines.push('    这些包从 asar 路径解析会 ENOENT；若壳应用代码 import 了它们，启动即崩。');
      }
      if (r.manifestOnly.length) {
        lines.push(`ℹ️  asar 清单有而 runtime 没有（${r.manifestOnly.length} 个，无实体，一般无害）：${r.manifestOnly.join(', ')}`);
      }
    } else {
      lines.push('');
      lines.push(`✅ asar 清单与 runtime 包名集合一致（${r.manifestCount} 包）。`);
    }
  } else {
    lines.push('打包模式: 未安装 Desktop（跳过 asar 检查）');
  }

  const specKeys = Object.keys(r.specs);
  if (specKeys.length) {
    lines.push('');
    lines.push(`壳应用代码 import 的 runtime 包（扫描文件 ${r.fileCount} 个，来源 ${r.mode === 'packed' ? 'asar 正文' : 'app.asar.unpacked'}）:`);
    for (const spec of specKeys.sort()) {
      const c = r.specs[spec];
      lines.push(`  ${spec}: ${c.ok ? `✅ 可解析（导出 ${c.count} 个）` : `⚠️  未解析（${c.why}）`}`);
    }
  } else if (r.asarFound) {
    lines.push('');
    lines.push('⚠️  未扫到任何壳应用代码（扫描 0 个文件）—— 预检等于没做，请回报此情况（asar 布局可能又变了）。');
  }

  if (r.conflicts.length && r.fatal) {
    lines.push('');
    lines.push(`❌ 检出 ${r.conflicts.length} 处致命冲突（壳主进程加载即崩）:`);
    for (const c of r.conflicts) {
      lines.push(`  import { ${c.name} } from '${c.spec}'`);
      lines.push(`    位置: ${c.file}`);
      lines.push(`    基准（当前 runtime）实际导出: ${c.have.join(', ') || '(无)'}`);
    }
    lines.push('');
    lines.push('建议（任选其一）：');
    if (r.mode === 'shared') {
      lines.push('  1. 等 Desktop 官方发布适配当前 runtime 基线的新版本后升级 Desktop（dsm shell）');
      lines.push('  2. dsm rollback runtime 回到与 Desktop 打包基线一致的版本');
    } else {
      lines.push(`  1. 壳自带副本与 CLI runtime 版本一致（${r.bundledVersion}），说明壳基线本身就缺这个导出：升级 Desktop（dsm shell）或回报上游`);
      lines.push('  2. dsm rollback runtime —— 但注意自包含模式下回退 CLI runtime 不会改变壳行为');
    }
    lines.push('  3. 升级 runtime 前先跑 dsm check 预判（本检查）');
  } else if (r.conflicts.length) {
    lines.push('');
    lines.push(`⚠️  检出 ${r.conflicts.length} 处 API 差异——**仅供参考，未必影响壳运行**：`);
    lines.push(`    壳为自包含（自带 dsh ${r.bundledVersion || '未知'}），它的 import 由自带副本解析，`);
    lines.push(`    而本次比对基准是 CLI runtime（${r.runtimeVersion || '未知'}）。两端版本不一致时差异属预期。`);
    for (const c of r.conflicts) {
      lines.push(`  import { ${c.name} } from '${c.spec}'`);
      lines.push(`    位置: ${c.file}`);
      lines.push(`    基准（CLI runtime）实际导出: ${c.have.join(', ') || '(无)'}`);
    }
    lines.push('');
    lines.push(`    想查壳的真实 API 面，请在 bundledVersion === runtimeVersion 时再跑本检查（当前不等）。`);
  } else if (r.unresolved.length) {
    const uniq = [...new Set(r.unresolved.map((u) => `${u.spec}: ${u.why}`))];
    lines.push('');
    lines.push(`⚠️  ${uniq.length} 个包无法静态解析（非确定冲突，需人工确认）:`);
    for (const u of uniq) lines.push(`  ${u}`);
  } else {
    lines.push('');
    lines.push(r.mode === 'packed'
      ? '✅ 壳应用代码 import 的符号在比对基准中都存在。'
      : '✅ 应用代码 import 的符号在当前 runtime 中均存在，主进程可加载。');
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

  const critical = r.fatal;
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

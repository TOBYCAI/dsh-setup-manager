#!/usr/bin/env node
// scan-adapters.mjs — 扫描已装 LLM adapter，检查其与当前 runtime 的 @deepseek-ai/dsh 版本兼容性。
//
// 用法：
//   node scan-adapters.mjs [--dsh-home <dir>]
// 默认 DSH_HOME=$HOME/.dsh。
//
// 背景：rc.2 是一次破坏性 adapter 接口变更（每个 LLM adapter 须实现 prepareCall 等新方法）。
// 上游已在 modlens ≥3.23.x 修好 prepareCall，所以「缺方法」不再是问题；真正要警惕的是
// 「adapter 声明的 @deepseek-ai/dsh peer/依赖范围」与「你实际装的 runtime dsh 版本」是否匹配——
// 一旦升级 runtime 把 dsh 升到 adapter 不支持的范围，web 启动就会崩。本脚本给出可读的兼容性报告，
// 并额外预测「若升级到 next/latest 会否有 adapter 掉出范围」，方便升级前判断破坏性。

import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { execSync } from 'node:child_process';

const args = process.argv.slice(2);
function getArg(flag) {
  const i = args.indexOf(flag);
  return i >= 0 ? args[i + 1] : undefined;
}
const home = getArg('--dsh-home') || process.env.DSH_HOME || join(process.env.HOME, '.dsh');

// ---------- 极简 semver 范围判定（覆盖 ^ ~ >= <= > < x.y.* 与 || 组合）----------
function parseV(v) {
  v = (v || '').replace(/^v/, '');
  const m = v.match(/^(\d+)\.(\d+)\.(\d+)/);
  return m ? [+m[1], +m[2], +m[3]] : null;
}
function cmp(a, b) {
  for (let i = 0; i < 3; i++) { if (a[i] < b[i]) return -1; if (a[i] > b[i]) return 1; }
  return 0;
}
function satisfies(range, ver) {
  if (!range || range === '*' || range === 'x' || range === '') return true;
  const V = parseV(ver);
  if (!V) return false;
  if (range.includes('||')) return range.split('||').some((r) => satisfies(r.trim(), ver));
  if (range.includes(' ')) return range.split(/\s+/).every((r) => satisfies(r, ver));
  range = range.trim();
  let m;
  if ((m = range.match(/^\^(\d+)\.(\d+)\.(\d+)/))) {
    const M = +m[1], m2 = +m[2];
    if (V[0] !== M) return false;
    if (M > 0) return cmp(V, [M, m2, 0]) >= 0;
    if (m2 > 0) return V[0] === 0 && V[1] === m2 && cmp(V, [0, m2, 0]) >= 0;
    return V[0] === 0 && V[1] === 0;
  }
  if ((m = range.match(/^~(\d+)\.(\d+)\.(\d+)/))) {
    return V[0] === +m[1] && V[1] === +m[2];
  }
  if ((m = range.match(/^>=?(\d+)\.(\d+)\.(\d+)/))) return cmp(V, [+m[1], +m[2], +m[3]]) >= (range[0] === '>' ? 1 : 0);
  if ((m = range.match(/^<=?(\d+)\.(\d+)\.(\d+)/))) return cmp(V, [+m[1], +m[2], +m[3]]) <= (range[0] === '<' ? -1 : 0);
  if ((m = range.match(/^(\d+)\.\*$/))) return V[0] === +m[1];
  if ((m = range.match(/^(\d+)\.(\d+)\.\*$/))) return V[0] === +m[1] && V[1] === +m[2];
  if ((m = range.match(/^(\d+)\.(\d+)\.(\d+)$/))) return cmp(V, [+m[1], +m[2], +m[3]]) === 0;
  return false;
}

// ---------- 版本来源 ----------
function installedDsh() {
  const p = join(home, 'runtime/node_modules/@deepseek-ai/dsh/package.json');
  if (existsSync(p)) { try { return JSON.parse(readFileSync(p)).version; } catch {} }
  try { return execSync('dsh --version').toString().trim().split('\n')[0] || null; } catch { return null; }
}
function distTags() {
  try { return JSON.parse(execSync('npm view @deepseek-ai/dsh dist-tags --json').toString()); } catch { return {}; }
}

// ---------- 扫描已装 adapter ----------
function findAdapters() {
  const out = new Map(); // name -> {version, dshRange, path}
  const roots = [
    join(home, 'profiles/node_modules/@deepseek-ai'),
    join(home, 'profiles/node_modules/.pnpm'),
  ];
  for (const root of roots) {
    if (!existsSync(root)) continue;
    const candidates = [];
    if (root.endsWith('@deepseek-ai')) {
      for (const name of readdirSync(root)) {
        const pkg = join(root, name, 'package.json');
        if (existsSync(pkg)) candidates.push(pkg);
      }
    } else {
      // .pnpm：路径形如 <scope+name>@ver/node_modules/<scope>/<name>/package.json
      for (const dir of readdirSync(root)) {
        const base = join(root, dir, 'node_modules');
        if (!existsSync(base)) continue;
        for (const scopeOrName of readdirSync(base)) {
          const full = join(base, scopeOrName);
          let pkg;
          if (scopeOrName.startsWith('@')) {
            for (const n of readdirSync(full)) {
              pkg = join(full, n, 'package.json');
              if (existsSync(pkg)) candidates.push(pkg);
            }
          } else {
            pkg = join(full, 'package.json');
            if (existsSync(pkg)) candidates.push(pkg);
          }
        }
      }
    }
    for (const pkg of candidates) {
      let j;
      try { j = JSON.parse(readFileSync(pkg)); } catch { continue; }
      const name = j.name;
      if (!name) continue;
      const dshRange = (j.peerDependencies && j.peerDependencies['@deepseek-ai/dsh'])
        || (j.dependencies && j.dependencies['@deepseek-ai/dsh']);
      // 只关心真正与 dsh 版本耦合的 adapter：要么显式声明了 @deepseek-ai/dsh 范围，
      // 要么是 LLM adapter（dsh-llm*）。不再把整个 @deepseek-ai/dsh-* 全家桶列出来（那是 dsh 本体）。
      if (!dshRange && !/^@deepseek-ai\/dsh-llm/i.test(name)) continue;
      if (out.has(name)) continue; // 去重，取第一个
      out.set(name, { version: j.version || '?', dshRange: dshRange || null, path: pkg });
    }
  }
  return out;
}

// ---------- 输出 ----------
const inst = installedDsh();
const tags = distTags();
const next = tags.next || null;
const latest = tags.latest || null;

console.log('=== 已装 adapter 与 runtime 兼容性扫描 ===');
console.log(`runtime @deepseek-ai/dsh: ${inst || '?'}（next=${next || '无'} latest=${latest || '无'}）\n`);

if (!inst) {
  console.log('⚠ 无法确定当前 runtime dsh 版本，仅列出已装 adapter 及其声明范围。\n');
}

const adapters = findAdapters();
if (adapters.size === 0) {
  console.log('未发现与 @deepseek-ai/dsh 相关的 adapter 包。');
  process.exit(0);
}

let problem = 0;
const rows = [];
for (const [name, info] of [...adapters.entries()].sort()) {
  const range = info.dshRange;
  const okNow = range ? satisfies(range, inst) : null;
  const okNext = next && range ? satisfies(range, next) : null;
  const okLatest = latest && range ? satisfies(range, latest) : null;
  let status = '—';
  if (range) {
    if (okNow === false) { status = '❌ 当前版本不兼容'; problem++; }
    else if (okNext === false || okLatest === false) { status = '⚠ 升级后可能不兼容'; problem++; }
    else status = '✅ 兼容';
  } else {
    status = 'ℹ 未声明 dsh 范围';
  }
  rows.push({ name, ver: info.version, range: range || '(无)', status, okNext, okLatest });
}

// 表头
const cols = ['adapter', 'version', 'dsh 范围', '状态', '升级到 next', '升级到 latest'];
const fmt = (s, w) => (s + ' '.repeat(Math.max(0, w - [...s].length)));
console.log(fmt(cols[0], 34) + fmt(cols[1], 12) + fmt(cols[2], 22) + fmt(cols[3], 18) + fmt(cols[4], 14) + cols[5]);
for (const r of rows) {
  console.log(
    fmt(r.name, 34) +
    fmt(r.ver, 12) +
    fmt(r.range, 22) +
    fmt(r.status, 18) +
    fmt(next ? (r.okNext === false ? '❌ 掉范围' : r.okNext === true ? '✅' : '—') : '—', 14) +
    (latest ? (r.okLatest === false ? '❌ 掉范围' : r.okLatest === true ? '✅' : '—') : '—')
  );
}

console.log('\n读表要点：');
console.log('- 「升级到 next/latest」列预测：若把 runtime dsh 升到该版本，adapter 是否会掉出它声明的范围。');
console.log('- ❌ 表示确定不兼容；⚠ 表示当前兼容但升级后有风险；升级前请先确认有 ⚠ 的 adapter 是否发了新版本。');
console.log('- prepareCall 类「缺方法」问题上游已在 modlens ≥3.23.x 修复，本工具不再需要手动补丁。');
process.exit(problem > 0 ? 1 : 0);

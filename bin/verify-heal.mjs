#!/usr/bin/env node
// verify-heal.mjs — 模拟 DSH 桌面 App 启动时的 heal，校验 Profile 关键包是否仍解析到 runtime。
//
// 用法：
//   node verify-heal.mjs [--dsh-home <dir>] [--app-pkg <dir>]
// 默认 DSH_HOME=$HOME/.dsh，app-pkg 取 macOS 壳内 @deepseek-ai 目录（不存在则仅检查 profiles）。
//
// 背景：pin-runtime.sh 把 App 包/profiles 的 @deepseek-ai/* 软链到 runtime。
// 本脚本调用 dsh-app-boot 的 healProfilesModuleFallback() 复现启动自愈，
// 再检查关键包（dsh/cordis/cosmokit/dsh-base/dsh-app-boot/dsh-web-app/dsh-desktop-app）
// 的 realpath 是否落在 ~/.dsh/runtime/ 下。全部命中即说明 runtime 权威、壳盖不到。

import { realpathSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const args = process.argv.slice(2);
function getArg(flag) {
  const i = args.indexOf(flag);
  return i >= 0 ? args[i + 1] : undefined;
}

const home = getArg('--dsh-home') || process.env.DSH_HOME || join(process.env.HOME, '.dsh');
const appPkg = getArg('--app-pkg') ||
  (existsSync('/Applications/DSH Desktop.app/Contents/Resources/app.asar.unpacked/package.json')
    ? '/Applications/DSH Desktop.app/Contents/Resources/app.asar.unpacked/package.json'
    : null);

const runtimeBoot = join(home, 'runtime/node_modules/@deepseek-ai/dsh-app-boot/lib/index.js');
if (!existsSync(runtimeBoot)) {
  console.error(`✗ 未找到 dsh-app-boot: ${runtimeBoot}`);
  process.exit(1);
}
const boot = await import(runtimeBoot);
const anchor = appPkg || join(home, 'runtime/node_modules/@deepseek-ai/dsh/package.json');
const anchorExists = existsSync(anchor);
if (anchorExists) {
  boot.healProfilesModuleFallback(anchor, home);
} else {
  console.warn('⚠ 未提供 app-pkg，跳过 heal 模拟，仅检查现有 profiles 链接。');
}

const base = join(home, '.dsh/profiles/node_modules/@deepseek-ai');
const pkgs = ['dsh', 'cordis', 'cosmokit', 'dsh-base', 'dsh-app-boot', 'dsh-web-app', 'dsh-desktop-app'];
let allRuntime = true;
for (const p of pkgs) {
  const link = join(base, p);
  if (!existsSync(link)) { console.log(`BAD ${p} 缺失`); allRuntime = false; continue; }
  let rp;
  try { rp = realpathSync(link); } catch (e) { console.log(`BAD ${p} ERR ${e.message}`); allRuntime = false; continue; }
  const ok = rp.includes('/.dsh/runtime/') || rp.includes(join(home, 'runtime'));
  if (!ok) allRuntime = false;
  console.log(`${ok ? 'OK ' : 'BAD'} ${p} -> runtime=${ok}  (${rp.split('/.dsh/')[1] || rp})`);
}
console.log(allRuntime
  ? '\nRESULT: 所有关键包经 heal 后仍解析到 runtime ✅'
  : '\nRESULT: 存在未指向 runtime 的包 ❌（请重跑 pin-runtime.sh）');
process.exit(allRuntime ? 0 : 1);

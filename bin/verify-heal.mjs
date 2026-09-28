#!/usr/bin/env node
// verify-heal.mjs — 模拟 DSH 桌面 App 启动时的 heal，校验 Profile 关键包是否仍解析到 runtime。
//
// 用法：
//   node verify-heal.mjs [--dsh-home <dir>] [--app-pkg <dir>]
// 默认 DSH_HOME=$HOME/.dsh，app-pkg 取 macOS 壳内 @deepseek-ai 目录（不存在则仅检查 profiles）。
//
// 背景：pin-runtime.sh 把 App 包/profiles 的 @deepseek-ai/* 软链到 runtime。
//   ≤ dsh 0.1.7-alpha.1：桌面启动时壳用 dsh-app-boot 的 healProfilesModuleFallback()
//     按 App 的依赖闭包重建 profiles 软链 —— 本脚本先复现该自愈再校验结果，
//     以捕捉「pin 完又被壳打回」的情况。
//   ≥ dsh 0.1.7-alpha.1：该导出已从 dsh-app-boot 删除，壳不再改写 profiles 软链
//     （软链由 dsm pin 建立后长期有效）—— 脚本自动降级为**静态校验**现有软链。
// 校验方式：逐个读取关键包的 realpath 是否落在 ~/.dsh/runtime/ 下，
// 全部命中即说明 runtime 权威、壳盖不到。

import { realpathSync, existsSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const args = process.argv.slice(2);
function getArg(flag) {
  const i = args.indexOf(flag);
  return i >= 0 ? args[i + 1] : undefined;
}

const home = getArg('--dsh-home') || process.env.DSH_HOME || join(process.env.HOME, '.dsh');
// 锚点：优先壳内 app.asar.unpacked/package.json（共享软链模式 ≤2.0.5 有）；
// 自包含壳（≥2.0.7）把 node_modules 打进 asar、unpacked 下没有 package.json，
// 此时退回 runtime 的 dsh/package.json —— 语义正好是我们想验证的
// 「profiles 的 @deepseek-ai/* 应解析到 runtime」，对 CLI/web 侧依然有效。
const appPkg = getArg('--app-pkg') ||
  (existsSync('/Applications/DSH Desktop.app/Contents/Resources/app.asar.unpacked/package.json')
    ? '/Applications/DSH Desktop.app/Contents/Resources/app.asar.unpacked/package.json'
    : null);
if (!appPkg && !getArg('--app-pkg')) {
  console.log('ℹ️  壳内无 app.asar.unpacked/package.json（自包含壳或未安装壳）：'
    + '改用 runtime 的 dsh/package.json 作锚点，验证 profiles 是否解析到 runtime。');
}

const runtimeBoot = join(home, 'runtime/node_modules/@deepseek-ai/dsh-app-boot/lib/index.js');
if (!existsSync(runtimeBoot)) {
  console.error(`✗ 未找到 dsh-app-boot: ${runtimeBoot}`);
  process.exit(1);
}
const boot = await import(runtimeBoot);
const anchor = appPkg || join(home, 'runtime/node_modules/@deepseek-ai/dsh/package.json');
const anchorExists = existsSync(anchor);
// heal 只在旧版 dsh 可用：dsh 0.1.7-alpha.1 起 dsh-app-boot 已删除该导出
// （壳不再改写 profiles 软链，由 dsm pin 建立后长期有效）→ 降级为静态校验。
// 这里必须先做 typeof 判定：缺失时直接调用会抛 TypeError，
// 被 doctor 当成「存在未指向 runtime 的包」的假阳性。
const canHeal = typeof boot.healProfilesModuleFallback === 'function';
let healed = false;
if (anchorExists && canHeal) {
  boot.healProfilesModuleFallback(anchor, home);
  healed = true;
} else if (anchorExists) {
  console.log('ℹ️  当前 dsh-app-boot 未提供 healProfilesModuleFallback'
    + '（dsh 0.1.7-alpha.1 起已移除）：');
  console.log('    跳过 heal 模拟，改为直接校验现有 profiles 软链'
    + '（0.1.7 起由 dsm pin 建立、壳不再覆盖）。');
} else {
  console.warn('⚠ 未提供 app-pkg，跳过 heal 模拟，仅检查现有 profiles 链接。');
}

const base = (existsSync(join(home, 'profiles/node_modules/@deepseek-ai'))
  ? join(home, 'profiles/node_modules/@deepseek-ai')
  : join(home, 'profiles/web/node_modules/@deepseek-ai'));
if (!existsSync(base)) {
  console.warn(`⚠ 未找到 profiles 的 @deepseek-ai 目录（${base}）：`
    + 'profiles 可能尚未初始化，跳过软链校验（不视为失败）。');
  console.log('RESULT: 无可校验的 profiles 软链（未初始化）⚪');
  process.exit(0);
}
// 检查清单动态取自 runtime 中真实存在的 @deepseek-ai 包（版本无关，避免对 app-only / 已更名包误报）
let runtimePkgs = [];
try { runtimePkgs = readdirSync(join(home, 'runtime/node_modules/@deepseek-ai')); } catch { /* runtime 未初始化 */ }
const pkgs = runtimePkgs;
let allRuntime = true;
let checked = 0;
for (const p of pkgs) {
  const link = join(base, p);
  // profiles 未为此包建软链（app-only 形态，runtime 存在但壳直接提供）→ 不误报
  if (!existsSync(link)) continue;
  checked++;
  let rp;
  try { rp = realpathSync(link); } catch (e) { console.log(`BAD ${p} ERR ${e.message}`); allRuntime = false; continue; }
  const ok = rp.includes('/.dsh/runtime/') || rp.includes(join(home, 'runtime'));
  if (!ok) { allRuntime = false; console.log(`BAD ${p} -> 未解析到 runtime (${rp})`); }
}
console.log(healed
  ? '校验模式: 模拟启动自愈（healProfilesModuleFallback）'
  : '校验模式: 静态软链校验（当前 dsh 无 heal API，0.1.7-alpha.1 起已移除）');
console.log(allRuntime
  ? `\nRESULT: 所有关键包${healed ? '经 heal 后' : '（静态校验）'}仍解析到 runtime ✅`
    + `（共校验 ${checked} 个软链）`
  : '\nRESULT: 存在未指向 runtime 的包 ❌（请重跑 pin-runtime.sh）');
process.exit(allRuntime ? 0 : 1);

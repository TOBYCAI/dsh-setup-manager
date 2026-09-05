#!/usr/bin/env node
// Check and, when explicitly requested, rebuild the small audited set of native
// addons required during DSH boot. Installations keep lifecycle scripts disabled
// globally; this file is the narrow allow-list boundary.

import { existsSync, readFileSync, readdirSync, realpathSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { spawnSync } from 'node:child_process'

const args = process.argv.slice(2)
const valueOf = (flag) => { const i = args.indexOf(flag); return i >= 0 ? args[i + 1] : undefined }
const repair = args.includes('--repair')
const quiet = args.includes('--quiet')
const dshHome = valueOf('--dsh-home') || process.env.DSH_HOME || join(process.env.HOME || '', '.dsh')
const root = resolve(valueOf('--root') || join(dshHome, 'runtime'))
const pnpmDir = join(root, 'node_modules', '.pnpm')

const allowList = [{
  name: 'fs-ext',
  version: /^2\.1\.1$/,
  install: 'node-gyp configure build',
}]

function candidates(rule) {
  const out = []
  const direct = join(root, 'node_modules', rule.name)
  if (existsSync(join(direct, 'package.json'))) out.push(direct)
  if (existsSync(pnpmDir)) {
    for (const entry of readdirSync(pnpmDir)) {
      if (!entry.startsWith(`${rule.name}@`)) continue
      const dir = join(pnpmDir, entry, 'node_modules', rule.name)
      if (existsSync(join(dir, 'package.json'))) out.push(dir)
    }
  }
  return [...new Set(out.map((p) => realpathSync(p)))]
}

function probe(dir) {
  return spawnSync(process.execPath, ['-e', 'require(process.argv[1])', dir], {
    cwd: root,
    encoding: 'utf8',
    env: process.env,
  })
}

if (!existsSync(join(root, 'node_modules'))) {
  if (!quiet) console.error(`SKIP native addons: ${root}/node_modules 不存在`)
  process.exit(2)
}

let failed = false
let found = 0
for (const rule of allowList) {
  for (const dir of candidates(rule)) {
    found++
    const pkg = JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8'))
    let result = probe(dir)
    if (result.status === 0) {
      if (!quiet) console.log(`OK ${pkg.name}@${pkg.version} native addon 可加载`)
      continue
    }
    if (!repair) {
      failed = true
      if (!quiet) console.error(`BAD ${pkg.name}@${pkg.version}: ${(result.stderr || result.stdout || '无法加载').trim().split('\n')[0]}`)
      continue
    }
    if (!rule.version.test(String(pkg.version)) || !pkg.scripts || pkg.scripts.install !== rule.install) {
      failed = true
      console.error(`REFUSE ${pkg.name}@${pkg.version}: 不在已审计 native build 白名单内`)
      continue
    }
    console.log(`REBUILD ${pkg.name}@${pkg.version} (${rule.install})`)
    result = spawnSync('npm', ['run', 'install'], {
      cwd: dir,
      stdio: 'inherit',
      env: { ...process.env, npm_config_ignore_scripts: 'false' },
    })
    const verified = result.status === 0 ? probe(dir) : result
    if (verified.status !== 0) {
      failed = true
      console.error(`BAD ${pkg.name}@${pkg.version}: 重建后仍无法加载`)
    } else {
      console.log(`OK ${pkg.name}@${pkg.version} 已重建并通过加载验证`)
    }
  }
}

if (!found && !quiet) console.log('OK 当前安装没有已知的必需 native addon')
process.exit(failed ? 1 : 0)

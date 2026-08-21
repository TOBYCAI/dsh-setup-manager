# modlens `prepareCall` 兼容补丁（DSH rc.2 adapter API 变更）

## 问题现象

升级到 `@deepseek-ai/dsh@0.1.1-rc.2` 后，web 启动报：

```
本轮运行失败 registration.adapter.prepareCall is not a function
```

## 根因

rc.2 改了 LLM adapter 接口：`dsh-llm` 的 `prepareCall(config, signal)` 内部会调用
`registration.adapter.prepareCall(provider, model, signal)`，要求 **每个 LLM adapter
都必须实现 `prepareCall`**。

第三方插件 `@liustack/modlens`（截至 3.22.2 / 3.23.0）的 LLM adapter 没有实现该方法，
于是 web 启动时崩溃。这不是 runtime 升级失败，而是某个已装插件未适配新 adapter API。

## 补丁内容

在 modlens 的 `dsh/index.js`（LLM adapter 出口）补上 `prepareCall`：

```js
async prepareCall(_provider, model, signal) {
  const info = await this.resolveModel(_provider, model, signal)
  return { model: info, stream: this.stream.bind(this) }
}
```

## 如何固化（pnpm patch）

在 web profile 目录（`~/.dsh/profiles/web`）执行：

```bash
# 1) 生成 patch 脚手架
pnpm patch @liustack/modlens@3.23.0
# 按提示编辑临时目录里的 dsh/index.js，加入上面的 prepareCall 方法
# 2) 生成补丁文件（写入 patches/）
pnpm patch-commit <临时目录路径>
# 3) 在 package.json / pnpm-workspace.yaml 登记 patchedDependencies，重新安装
pnpm install
```

本项目 `bin/` 之外不内置该 patch，因为：
- 上游 `@liustack/modlens` > 3.23.0 **原生支持 rc.2 后应直接移除补丁**；
- 补丁需匹配你实际安装的 modlens 版本，硬编码反而容易失效。

## 适用条件

- 仅当报错信息为 `registration.adapter.prepareCall is not a function` 且堆栈指向某第三方
  LLM adapter 插件时适用。
- 若是 **其他** 插件缺 `prepareCall`，按同样模式给那个插件打补丁即可。
- 若是 runtime 自身的 adapter 缺方法，那是上游 bug，应回退版本或等修复，不要自行补。

## 验证

重启 `dsh web` 后在浏览器发一条消息，不再报 `prepareCall` 即修复成功。

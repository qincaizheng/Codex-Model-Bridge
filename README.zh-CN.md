# Codex Model Bridge

[English](README.md) | [中文](README.zh-CN.md)

Codex Model Bridge 是一个本地 `mitmdump` 启动桥，用来在当前名为 ChatGPT 的
桌面应用（以及旧版 Codex）启动阶段捕获 Statsig 初始化请求和模型列表请求，并把
自定义模型 catalog 注入到返回体里。启动脚本继续兼容旧版 Codex 安装，并有意保留
稳定的 Codex 命名配置项和日志标识。

本目录是独立项目。克隆或复制后，在本目录中运行对应平台脚本：

macOS:

```bash
./start-macos.sh
```

Linux:

```bash
./start-linux.sh
```

Windows PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\start-windows.ps1
```

脚本不接受命令行参数；本地配置统一写在 `config.json`。

## 配置

默认配置：

```json
{
  "codex_app_path": "",
  "model_source": "catalog_json",
  "catalog_json": "",
  "api_base_url": "",
  "api_key": "",
  "upstream_proxy": "",
  "ab_fallback_timeout_seconds": 8,
  "enable_i18n": true,
  "locale_source": "FIRST_AVAILABLE",
  "desired_model": "gpt-5.5"
}
```

字段说明：

- `codex_app_path`：为兼容性保留的配置键，可填写 ChatGPT 或旧版 Codex 的
  应用/可执行文件路径。留空时脚本会自动检测。相对路径以 `config.json` 所在目录为
  基准解析，而不是 shell 的当前目录。macOS 可填写 `.app` bundle（脚本会从
  `Info.plist` 读取 `CFBundleExecutable`）或直接填写可执行文件路径。
- `model_source`：模型来源，可选 `catalog_json`、`api` 或 `both`。
- `catalog_json`：本地模型 catalog 路径。留空时会先找 `config.json`
  同目录下的 `models_catalog.json`，再找当前用户 `.codex` 目录下的
  `models_catalog.json`。也可以直接填绝对路径或相对路径。
- `api_base_url`：OpenAI 兼容接口的 base URL。使用 `api` 或 `both` 时，
  插件会请求 `${api_base_url}/models`。
- `api_key`：`api_base_url` 的可选 bearer token。
- `upstream_proxy`：mitmdump 出站流量使用的可选 HTTP(S) 代理。搭配
  FlClash 时可设置为 `http://127.0.0.1:7890`。
- `ab_fallback_timeout_seconds`：AB 启动请求挂住时触发本地兜底返回的超时
  秒数。设置为 `0` 时保留 mitmproxy 默认 TCP 超时。这个值会作为当前
  helper 进程的 mitmproxy `tcp_timeout` 生效。
- `enable_i18n`：在 AB initialize 返回体里启用 ChatGPT/Codex 的 UI 本地化 layer。
- `locale_source`：UI 语言来源，可选 `IDE`、`SYSTEM` 或
  `FIRST_AVAILABLE`。具体手动语言覆盖值是桌面应用本地的 `localeOverride`
  setting，不是直接放在 AB 返回体里。
- `desired_model`：要注入并设为默认值的模型。

`host` 和 `path` 不需要配置，项目固定处理：

```text
ab.chatgpt.com/v1/initialize
*/models
```

## 工作方式

流量链路：

```text
ChatGPT/Codex --no-proxy-server -> mitmproxy local capture -> optional upstream_proxy
```

脚本启动后会优先检测当前 ChatGPT 应用，并回退兼容旧版 Codex；随后安装或复用
`mitmdump`、确保证书可用，并在目标应用启动前开启本地捕获。目标应用会以绕过
系统代理的方式启动，避免直接连到系统代理端口导致 mitmproxy local mode 捕获不到。
捕获选择器既包含 ChatGPT 主进程，也有意保留 Codex 命名的 Chromium helper 与
旧版 Codex 进程。

启动新的捕获前，脚本会自动停止使用同一个 `rewrite.py` 的旧 mitmdump 捕获进程。
这只清理旧 mitmdump，不会自动杀掉 ChatGPT/Codex 本体。

当 `ab.chatgpt.com/v1/initialize` 进入 addon 后，插件会自己执行这次上游请求。
如果上游请求失败，或者超过 `ab_fallback_timeout_seconds` 仍未完成，插件会直接
返回缓存/模板版本的 Statsig initialize 值，保留上次上游成功响应的字段，同时继续
注入配置模型、设置默认模型，并按 `enable_i18n` 与 `locale_source` 注入
ChatGPT/Codex 的 UI 本地化 layer。首次运行或没有缓存快照时，使用脱敏的初始化模板
（`statsig-fallback/init-template.json`）并将其写入本地缓存。启动脚本也会
强制使用 mitmproxy 的 `connection_strategy=lazy`，避免 mitmproxy 在 addon 看到
请求之前就提前连接上游。

当 `upstream_proxy` 有值时，ChatGPT/Codex 本身仍然绕过系统代理，但 mitmdump
会把捕获到的出站流量转发给这个上游代理。

新机器第一次启动时，建议先保证可用的代理链路：开启代理客户端的 TUN 模式，或在
`config.json` 里配置 `upstream_proxy`。这样 addon 更容易先拿到并保存一份真实上游
Statsig 快照，之后再进入模板兜底时字段会更完整。

## 平台说明

- macOS 需要启用 Mitmproxy Redirector network extension。当前安装通常是
  `/Applications/ChatGPT.app`，主可执行文件为 `ChatGPT`，bundle ID 仍为
  `com.openai.codex`，Chromium helper 也仍使用 Codex 命名；脚本会回退检测
  `Codex.app`。
- Linux 请用桌面用户运行脚本，不要直接用 `sudo` 运行。
- Windows Store 版本会通过 app execution alias 或 AUMID 启动，避免直接执行
  `WindowsApps` 路径时遇到权限问题。ChatGPT 与 Codex 的 alias、包名和可执行文件名
  都会被识别。

## 推荐配合

推荐搭配 [ZhiYi-R/moon-bridge](https://github.com/ZhiYi-R/moon-bridge) 使用。

## 日志

前台输出会尽量保持简短。macOS 和 Linux 会把目标应用 stderr 与 mitmproxy core
日志写入本地日志文件，只把包含 `[codex-patch]` 的 addon 行回显到终端。Windows
会把 mitmdump 输出和直接启动 ChatGPT/Codex 时的进程输出写到
`%LOCALAPPDATA%\CodexModelBridge\Logs`。

日志位置：

```text
macOS:   ~/Library/Logs/CodexModelBridge/
Linux:   ${XDG_STATE_HOME:-~/.local/state}/CodexModelBridge/
Windows: %LOCALAPPDATA%\CodexModelBridge\Logs\
```

常见有效 addon 日志：

```text
[codex-patch] AB request patched: ...
[codex-patch] AB response patched: ...
[codex-patch] AB fallback response built: ...
[codex-patch] Models response patched: ...
```

修改 `rewrite.py` 或 `config.json` 后，需要完全退出 ChatGPT/Codex（包括残留后台
进程）并重新运行启动脚本；mitmproxy addon 不会热加载已运行进程中的旧代码。

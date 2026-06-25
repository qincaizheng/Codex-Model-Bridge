# Codex Model Bridge

[English](README.md) | [中文](README.zh-CN.md)

Codex Model Bridge 是一个本地 `mitmdump` 启动桥，用来在 Codex 启动阶段捕获
Statsig 初始化请求和模型列表请求，并把自定义模型 catalog 注入到返回体里。

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
  "desired_model": "gpt-5.5"
}
```

字段说明：

- `codex_app_path`：Codex 应用路径。留空时脚本会自动检测。
- `model_source`：模型来源，可选 `catalog_json`、`api` 或 `both`。
- `catalog_json`：本地模型 catalog 路径。留空时会先找 `config.json`
  同目录下的 `models_catalog.json`，再找当前用户 `.codex` 目录下的
  `models_catalog.json`。也可以直接填绝对路径或相对路径。
- `api_base_url`：OpenAI 兼容接口的 base URL。使用 `api` 或 `both` 时，
  插件会请求 `${api_base_url}/models`。
- `api_key`：`api_base_url` 的可选 bearer token。
- `upstream_proxy`：mitmdump 出站流量使用的可选 HTTP(S) 代理。搭配
  FlClash 时可设置为 `http://127.0.0.1:7890`。
- `desired_model`：要注入并设为默认值的模型。

`host` 和 `path` 不需要配置，项目固定处理：

```text
ab.chatgpt.com/v1/initialize
*/models
```

## 工作方式

流量链路：

```text
Codex --no-proxy-server -> mitmproxy local capture -> optional upstream_proxy
```

脚本启动后会检测 Codex、安装或复用 `mitmdump`、确保证书可用，然后在 Codex
启动前开启本地捕获。Codex 会以绕过系统代理的方式启动，避免直接连到系统代理
端口导致 mitmproxy local mode 捕获不到。

如果 `ab.chatgpt.com/v1/initialize` 已经进入 mitmproxy，但网络或上游代理不可用，
插件会本地构造 Statsig initialize 返回值，继续注入配置模型并设置默认模型。

当 `upstream_proxy` 有值时，Codex 本身仍然绕过系统代理，但 mitmdump 会把捕获到
的出站流量转发给这个上游代理。

## 平台说明

- macOS 需要启用 Mitmproxy Redirector network extension。
- Linux 请用桌面用户运行脚本，不要直接用 `sudo` 运行。
- Windows Store 版本会通过 app execution alias 或 AUMID 启动，避免直接执行
  `WindowsApps` 路径时遇到权限问题。

## 推荐配合

推荐搭配 [ZhiYi-R/moon-bridge](https://github.com/ZhiYi-R/moon-bridge) 使用。

## 日志

常见有效日志：

```text
[codex-patch] AB request patched: ...
[codex-patch] AB response patched: ...
[codex-patch] AB fallback response built: ...
[codex-patch] Models response patched: ...
```

修改 `rewrite.py` 或 `config.json` 后，需要退出 Codex 并重新运行启动脚本；
mitmproxy addon 不会热加载已运行进程中的旧代码。

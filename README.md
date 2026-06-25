# Codex mitmdump Local Patcher

This directory is self-contained. Run commands from this directory after you
clone or copy it.

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

The launchers accept no command-line arguments. Edit `config.json` instead.

## Config

`config.json` lives next to the scripts:

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

Relative paths are resolved relative to `config.json`, not the shell's current
directory.

Fields:

- `codex_app_path`: leave empty to auto-detect Codex. Set it only when the
  launcher cannot find the app.
- `model_source`: `catalog_json`, `api`, or `both`.
- `catalog_json`: local model catalog path. Leave empty to auto-detect
  `models_catalog.json` next to `config.json`, then
  `~/.codex/models_catalog.json`; or set an explicit JSON file.
- `api_base_url`: OpenAI-compatible base URL. The addon fetches
  `${api_base_url}/models` when `model_source` is `api` or `both`.
- `api_key`: optional bearer token for `api_base_url`.
- `upstream_proxy`: optional HTTP(S) proxy for mitmdump outbound traffic. For
  FlClash, set this to `http://127.0.0.1:7890`.
- `desired_model`: model to inject and make the default.

`host` and `path` are intentionally not configurable. The addon patches:

```text
ab.chatgpt.com/v1/initialize
*/models
```

## Behavior

The traffic path is:

```text
Codex --no-proxy-server -> mitmproxy local capture -> optional upstream_proxy
```

If the startup request to `ab.chatgpt.com/v1/initialize` fails because the
network or upstream proxy is unavailable, the addon builds a local fallback
Statsig initialize response with the configured models and desired default.

On startup the launcher:

1. Detects the Codex app path.
2. Refuses to continue if Codex is already running.
3. Installs `mitmdump` if missing.
4. Creates and trusts the mitmproxy CA if needed.
5. Starts mitmproxy local capture for Codex process names.
6. Launches Codex with system proxy variables cleared and Chromium proxy
   bypass flags enabled.

When `upstream_proxy` is set, Codex is still launched without the system proxy,
but mitmdump forwards captured outbound traffic through that proxy.

## Platform Notes

- macOS requires the Mitmproxy Redirector network extension to be enabled.
- Linux should be run as the desktop user, not with `sudo`.
- Windows Store installs are launched through the app execution alias or AUMID
  when direct `WindowsApps` execution is blocked.

## Recommended Companion

This project is recommended to use together with
[ZhiYi-R/moon-bridge](https://github.com/ZhiYi-R/moon-bridge).

## Logs

Normal useful lines look like:

```text
[codex-patch] AB request patched: ...
[codex-patch] AB response patched: ...
[codex-patch] AB fallback response built: ...
[codex-patch] Models response patched: ...
```

After changing `rewrite.py` or `config.json`, quit Codex and restart the
launcher. The mitmproxy addon is loaded at startup.

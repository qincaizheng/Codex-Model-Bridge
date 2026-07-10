# Codex Model Bridge

[English](README.md) | [中文](README.zh-CN.md)

This directory is self-contained. Run commands from this directory after you
clone or copy it.

The current desktop app is named ChatGPT. The launchers also remain compatible
with legacy Codex installations and intentionally keep stable Codex-named
configuration and logging identifiers.

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
  "ab_fallback_timeout_seconds": 8,
  "enable_i18n": true,
  "locale_source": "FIRST_AVAILABLE",
  "desired_model": "gpt-5.5"
}
```

Relative paths are resolved relative to `config.json`, not the shell's current
directory.

Fields:

- `codex_app_path`: retained compatibility key for either a ChatGPT or legacy
  Codex app/executable path. Leave it empty for auto-detection; set it only when
  the launcher cannot find the app. On macOS it accepts either a `.app` bundle
  (whose `CFBundleExecutable` is read from `Info.plist`) or a direct executable
  path.
- `model_source`: `catalog_json`, `api`, or `both`.
- `catalog_json`: local model catalog path. Leave empty to auto-detect
  `models_catalog.json` next to `config.json`, then
  `models_catalog.json` under the user's `.codex` directory; or set an
  explicit JSON file.
- `api_base_url`: OpenAI-compatible base URL. The addon fetches
  `${api_base_url}/models` when `model_source` is `api` or `both`.
- `api_key`: optional bearer token for `api_base_url`.
- `upstream_proxy`: optional HTTP(S) proxy for mitmdump outbound traffic. For
  FlClash, set this to `http://127.0.0.1:7890`.
- `ab_fallback_timeout_seconds`: timeout used to trigger the local AB fallback
  response when the startup request hangs. Set `0` to keep mitmproxy's default
  TCP timeout. This is applied as mitmproxy's `tcp_timeout` for this helper
  process.
- `enable_i18n`: enables the ChatGPT/Codex UI localization layer in the AB
  initialize response.
- `locale_source`: UI locale source for that layer. Supported values are
  `IDE`, `SYSTEM`, and `FIRST_AVAILABLE`. A specific manual language override
  is stored by the desktop app as its local `localeOverride` setting, not
  directly in the AB response.
- `desired_model`: model to inject and make the default.

`host` and `path` are intentionally not configurable. The addon patches:

```text
ab.chatgpt.com/v1/initialize
*/models
```

## Behavior

The traffic path is:

```text
ChatGPT/Codex --no-proxy-server -> mitmproxy local capture -> optional upstream_proxy
```

When the startup request to `ab.chatgpt.com/v1/initialize` enters the addon,
the addon performs the upstream request itself. If that upstream request fails
or exceeds `ab_fallback_timeout_seconds`, the addon returns a cached/template
Statsig initialize response that preserves fields from the last successful
upstream response, while still applying the configured models, desired default,
and UI localization layer (`enable_i18n`, `locale_source`). On the first run
or when no cached snapshot exists, a sanitized initialization template
(`statsig-fallback/init-template.json`) is used and seeded into the local cache.
The launchers also force mitmproxy's `connection_strategy=lazy`,
so mitmproxy does not try to connect upstream before the addon can see the
request.

On startup the launcher:

1. Detects the current ChatGPT app path, with legacy Codex fallback.
2. Refuses to continue if the resolved target is already running.
3. Installs `mitmdump` if missing.
4. Creates and trusts the mitmproxy CA if needed.
5. Stops any previous mitmdump capture using the same `rewrite.py`.
6. Starts mitmproxy local capture for the ChatGPT main process plus intentionally
   retained Codex-named Chromium helpers and legacy Codex processes.
7. Launches the resolved app with system proxy variables cleared and Chromium
   proxy bypass flags enabled.

When `upstream_proxy` is set, ChatGPT/Codex is still launched without the
system proxy, but mitmdump forwards captured outbound traffic through that
proxy.

For the first run on a new machine, prefer starting with a working proxy path:
enable your proxy client's TUN mode or set `upstream_proxy` in `config.json`.
That gives the addon a better chance to fetch and save a real upstream Statsig
snapshot before it ever needs the template fallback.

## Platform Notes

- macOS requires the Mitmproxy Redirector network extension to be enabled. The
  current install is normally `/Applications/ChatGPT.app` with executable
  `ChatGPT` and bundle ID `com.openai.codex`; its Chromium helpers remain
  Codex-named. `Codex.app` remains an auto-detected fallback.
- Linux should be run as the desktop user, not with `sudo`.
- Windows Store installs are launched through the app execution alias or AUMID
  when direct `WindowsApps` execution is blocked. Both ChatGPT and Codex aliases,
  package names, and executable names are recognized.

## Recommended Companion

This project is recommended to use together with
[ZhiYi-R/moon-bridge](https://github.com/ZhiYi-R/moon-bridge).

## Logs

The foreground output is intentionally short. On macOS and Linux, target app
stderr and mitmproxy core logs are written to local log files, and only addon
lines containing `[codex-patch]` are echoed to the terminal. Windows writes
mitmdump output and direct ChatGPT/Codex launch output under
`%LOCALAPPDATA%\CodexModelBridge\Logs`.

Log locations:

```text
macOS:   ~/Library/Logs/CodexModelBridge/
Linux:   ${XDG_STATE_HOME:-~/.local/state}/CodexModelBridge/
Windows: %LOCALAPPDATA%\CodexModelBridge\Logs\
```

Useful addon lines look like:

```text
[codex-patch] AB request patched: ...
[codex-patch] AB response patched: ...
[codex-patch] AB fallback response built: ...
[codex-patch] Models response patched: ...
```

After changing `rewrite.py` or `config.json`, fully quit ChatGPT/Codex, including
any remaining background process, and restart the launcher. The mitmproxy addon
is loaded at startup.

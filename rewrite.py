"""mitmproxy addon for Codex model-list and Statsig startup patching.

The network targets are intentionally hardcoded:

- Statsig startup config: ab.chatgpt.com/v1/initialize
- Provider model source: any Codex-captured request whose path ends in /models

Only local machine differences live in config.json: desired_model and where to
read model rows from. A model source can be a local catalog JSON file or a
configured OpenAI-compatible base URL plus API key. Statsig is only used to keep
those rows visible and choose the default model.
"""

from __future__ import annotations

import base64
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from copy import deepcopy
from typing import Any

from mitmproxy import ctx, http


STATSIG_HOST = "ab.chatgpt.com"
STATSIG_PATH_PREFIX = "/v1/initialize"
STATSIG_DYNAMIC_CONFIG_KEYS = ("107580212", "2523198654")
STATSIG_I18N_LAYER_CONFIG_KEY = "72216192"
STATSIG_LOCALE_SOURCE_VALUES = ("IDE", "SYSTEM", "FIRST_AVAILABLE")

DEFAULT_DESIRED_MODEL = "gpt-5.5"
DEFAULT_MODEL_SOURCE = "catalog_json"
DEFAULT_UPSTREAM_PROXY = ""
DEFAULT_AB_FALLBACK_TIMEOUT_SECONDS = 8
DEFAULT_ENABLE_I18N = True
DEFAULT_LOCALE_SOURCE = "FIRST_AVAILABLE"

STALE_HEADERS = ("content-length", "etag", "last-modified", "content-md5")
FALLBACK_RESPONSE_HEADERS = {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    "access-control-allow-origin": "*",
}
REQUEST_DELTA_KEYS = (
    "sinceTime",
    "previousDerivedFields",
    "partialUserMatchSinceTime",
)

STATSIG_FALLBACK_DIR = "statsig-fallback"
STATSIG_SNAPSHOT_CACHE_FILE = "snapshot.cache.json"
STATSIG_INIT_TEMPLATE_FILE = "init-template.json"


def _config_path() -> str:
    return os.environ.get(
        "MITM_REWRITE_CONFIG",
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.json"),
    )


def _script_dir() -> str:
    return os.path.dirname(os.path.abspath(__file__))


def _statsig_snapshot_dir() -> str:
    return os.path.join(_script_dir(), STATSIG_FALLBACK_DIR)


def _statsig_snapshot_path() -> str:
    return os.path.join(_statsig_snapshot_dir(), STATSIG_SNAPSHOT_CACHE_FILE)


def _statsig_init_template_path() -> str:
    return os.path.join(_statsig_snapshot_dir(), STATSIG_INIT_TEMPLATE_FILE)


DEFAULT_CATALOG_JSON = ""


def _resolve_config_path(value: str) -> str:
    expanded = os.path.expanduser(value)
    if os.path.isabs(expanded):
        return expanded
    return os.path.join(os.path.dirname(_config_path()), expanded)


def _default_catalog_candidates() -> tuple[str, ...]:
    home = os.path.expanduser("~")
    return (
        os.path.join(os.path.dirname(_config_path()), "models_catalog.json"),
        os.path.join(home, ".codex", "models_catalog.json"),
    )


def _find_default_catalog_path() -> str:
    candidates = _default_catalog_candidates()
    for path in candidates:
        if os.path.isfile(path):
            return path
    return candidates[0]


def _log(level: str, message: str) -> None:
    logger = ctx.log
    if level == "warn" and hasattr(logger, "warning"):
        logger.warning(message)
        return
    getattr(logger, level, logger.info)(message)


def _read_text(message) -> str:
    try:
        return message.get_text(strict=False)
    except TypeError:
        return message.get_text()


def _remove_stale_headers(headers) -> None:
    for name in STALE_HEADERS:
        try:
            headers.pop(name, None)
        except KeyError:
            pass


def _upstream_request_headers(headers) -> dict[str, str]:
    skipped = {
        "accept-encoding",
        "connection",
        "content-length",
        "host",
        "proxy-authorization",
        "proxy-connection",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
    }
    result: dict[str, str] = {}
    for name, value in headers.items(multi=True):
        if name.lower() not in skipped:
            result[name] = value
    result["Accept-Encoding"] = "identity"
    return result


def _request_path(request) -> str:
    return request.path.split("?", 1)[0]


def _request_hosts(request) -> tuple[str, ...]:
    hosts: list[str] = []
    for value in (
        getattr(request, "pretty_host", None),
        getattr(request, "host", None),
        request.headers.get("host"),
        request.headers.get(":authority"),
    ):
        if isinstance(value, str) and value:
            hosts.append(value.split(":", 1)[0].lower())
    return tuple(dict.fromkeys(hosts))


def _request_matches_host(request, expected: str) -> bool:
    return expected.lower() in _request_hosts(request)


def _is_statsig_initialize(request) -> bool:
    return (
        request.method.upper() == "POST"
        and _request_matches_host(request, STATSIG_HOST)
        and _request_path(request).startswith(STATSIG_PATH_PREFIX)
    )


def _is_models_response_candidate(request) -> bool:
    path = _request_path(request).rstrip("/")
    return request.method.upper() == "GET" and path.endswith("/models")


def _context_hosts(context) -> tuple[str, ...]:
    hosts: list[str] = []
    for conn_name in ("client", "server"):
        conn = getattr(context, conn_name, None)
        for value in (
            getattr(conn, "sni", None),
            getattr(conn, "address", (None, None))[0]
            if getattr(conn, "address", None)
            else None,
        ):
            if isinstance(value, str) and value:
                hosts.append(value.split(":", 1)[0].lower())
    return tuple(dict.fromkeys(hosts))


def _context_matches_host(context, expected: str) -> bool:
    return expected.lower() in _context_hosts(context)


def _query_value(request, name: str) -> str | None:
    try:
        value = request.query.get(name)
    except AttributeError:
        return None
    if isinstance(value, (list, tuple)):
        return value[0] if value else None
    return value


def _decode_se(raw: str) -> dict[str, Any]:
    decoded = base64.b64decode(raw[::-1])
    return json.loads(decoded)


def _encode_se(body: dict[str, Any]) -> str:
    compact = json.dumps(body, ensure_ascii=False, separators=(",", ":"))
    return base64.b64encode(compact.encode("utf-8")).decode("ascii")[::-1]


def _model_id(model: Any) -> str | None:
    if not isinstance(model, dict):
        return None
    value = model.get("id") or model.get("slug") or model.get("name")
    return value if isinstance(value, str) and value else None


def _openai_model_from_catalog(model: dict[str, Any]) -> dict[str, Any]:
    slug = model.get("slug") or model.get("id")
    if isinstance(model.get("id"), str):
        row = deepcopy(model)
        row.setdefault("object", "model")
        row.setdefault("created", 0)
        row.setdefault("owned_by", "openai")
        return row
    row = {
        "id": slug,
        "object": "model",
        "created": 0,
        "owned_by": "openai",
    }
    display_name = model.get("display_name")
    if isinstance(display_name, str):
        row["display_name"] = display_name
    return row


def _models_url(base_url: str) -> str:
    return base_url.rstrip("/") + "/models"


def _parse_upstream_proxy(value: str) -> tuple[str, tuple[str, int]] | None:
    if not isinstance(value, str) or not value.strip():
        return None

    raw = value.strip()
    if "://" not in raw:
        raw = "http://" + raw

    parsed = urllib.parse.urlparse(raw)
    if parsed.scheme not in ("http", "https"):
        raise ValueError("upstream_proxy only supports http:// or https://")
    if not parsed.hostname:
        raise ValueError("upstream_proxy is missing a host")
    try:
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
    except ValueError as exc:
        raise ValueError(f"upstream_proxy has invalid port: {exc}") from exc
    if parsed.username or parsed.password:
        raise ValueError("upstream_proxy with username/password is not supported")

    return parsed.scheme, (parsed.hostname, port)


def _parse_timeout_seconds(value: Any, default: int) -> int:
    if isinstance(value, bool):
        return default
    if isinstance(value, (int, float)):
        return max(0, int(value))
    if isinstance(value, str) and value.strip():
        try:
            return max(0, int(float(value.strip())))
        except ValueError:
            return default
    return default


def _parse_bool(value: Any, default: bool) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in ("1", "true", "yes", "on"):
            return True
        if normalized in ("0", "false", "no", "off"):
            return False
    return default


def _compact_value(value: Any) -> str:
    if isinstance(value, bool):
        return str(value).lower()
    if value is None:
        return "<none>"
    return str(value)


class CodexCatalogPatcher:
    def __init__(self) -> None:
        self.model_source = DEFAULT_MODEL_SOURCE
        self.catalog_path = _find_default_catalog_path()
        self.api_base_url = ""
        self.api_key = ""
        self.desired_model = DEFAULT_DESIRED_MODEL
        self.upstream_proxy = DEFAULT_UPSTREAM_PROXY
        self.ab_fallback_timeout_seconds = DEFAULT_AB_FALLBACK_TIMEOUT_SECONDS
        self.enable_i18n = DEFAULT_ENABLE_I18N
        self.locale_source = DEFAULT_LOCALE_SOURCE
        self.upstream_via: tuple[str, tuple[str, int]] | None = None
        self.catalog_models: list[dict[str, Any]] = []
        self.catalog_slugs: list[str] = []
        self._snapshot_dir_ensured = False

    def load(self, loader) -> None:
        self._load_config()
        self._apply_runtime_options()
        self._load_model_sources()

    def _apply_upstream_proxy(self, server) -> None:
        if not self.upstream_via:
            return
        if getattr(server, "transport_protocol", "tcp") != "tcp":
            return
        if getattr(server, "via", None):
            return

        _, proxy_address = self.upstream_via
        if server.address == proxy_address:
            return

        server.via = self.upstream_via

    def server_connect(self, data) -> None:
        self._apply_upstream_proxy(data.server)

    def tls_clienthello(self, data) -> None:
        sni = getattr(data.client_hello, "sni", None)
        if sni != STATSIG_HOST:
            return
        _log("error", f"[codex-patch] AB TLS clienthello: sni={sni}")

    def tls_established_client(self, data) -> None:
        if not _context_matches_host(data.context, STATSIG_HOST):
            return
        _log("error", f"[codex-patch] AB TLS client established: hosts={_context_hosts(data.context)}")

    def tls_failed_client(self, data) -> None:
        if not _context_matches_host(data.context, STATSIG_HOST):
            return
        _log("error", f"[codex-patch] AB TLS client failed: hosts={_context_hosts(data.context)}")

    def tls_failed_server(self, data) -> None:
        if not _context_matches_host(data.context, STATSIG_HOST):
            return
        _log("error", f"[codex-patch] AB TLS server failed: hosts={_context_hosts(data.context)}")

    def requestheaders(self, flow) -> None:
        self._apply_upstream_proxy(flow.server_conn)

    def request(self, flow) -> None:
        self._apply_upstream_proxy(flow.server_conn)
        request = flow.request
        if not _is_statsig_initialize(request):
            return

        flow.metadata["codex_patch_statsig_initialize"] = True
        raw = _read_text(request)
        if not raw:
            _log("error", "[codex-patch] Statsig request body is empty")
            return

        encoded = _query_value(request, "se") == "1"
        try:
            body = _decode_se(raw) if encoded else json.loads(raw)
        except (ValueError, TypeError) as exc:
            _log("error", f"[codex-patch] Could not decode Statsig request: {exc}")
            return
        if not isinstance(body, dict):
            _log("error", "[codex-patch] Statsig request JSON is not an object")
            return

        body["deltasResponseRequested"] = False
        body["full_checksum"] = None
        for key in REQUEST_DELTA_KEYS:
            body.pop(key, None)

        request.set_text(_encode_se(body) if encoded else json.dumps(body, ensure_ascii=False))
        _remove_stale_headers(request.headers)
        _log(
            "error",
            f"[codex-patch] AB request patched: host={getattr(request, 'pretty_host', request.host)} "
            f"path={_request_path(request)} encoded_se={encoded}",
        )
        self._resolve_statsig_request(flow)

    def response(self, flow) -> None:
        request = flow.request
        response = flow.response
        if _is_statsig_initialize(request):
            self._patch_statsig_response(flow, response)
            return

        if _is_models_response_candidate(request):
            self._patch_models_response(request, response)

    def error(self, flow) -> None:
        request = getattr(flow, "request", None)
        if request is None or not _is_statsig_initialize(request):
            return
        if getattr(flow, "response", None) is not None:
            return

        self._set_statsig_fallback_response(flow, reason="flow_error")

    def _load_config(self) -> None:
        path = _config_path()
        try:
            with open(path, encoding="utf-8") as f:
                config = json.load(f)
        except FileNotFoundError:
            config = {}
            _log("warn", f"[codex-patch] Config not found at {path}; using defaults")
        except (OSError, json.JSONDecodeError) as exc:
            config = {}
            _log("error", f"[codex-patch] Failed to load config {path}: {exc}")

        model_source = config.get("model_source", DEFAULT_MODEL_SOURCE)
        desired_model = config.get("desired_model", DEFAULT_DESIRED_MODEL)
        catalog_path = config.get("catalog_json", DEFAULT_CATALOG_JSON)
        api_base_url = config.get("api_base_url", "")
        api_key = config.get("api_key", "")
        upstream_proxy = config.get("upstream_proxy", DEFAULT_UPSTREAM_PROXY)
        ab_fallback_timeout_seconds = config.get(
            "ab_fallback_timeout_seconds",
            DEFAULT_AB_FALLBACK_TIMEOUT_SECONDS,
        )
        enable_i18n = config.get("enable_i18n", DEFAULT_ENABLE_I18N)
        locale_source = config.get("locale_source", DEFAULT_LOCALE_SOURCE)

        if isinstance(model_source, str) and model_source:
            self.model_source = model_source
        if isinstance(catalog_path, str) and catalog_path.strip():
            self.catalog_path = _resolve_config_path(catalog_path)
        else:
            self.catalog_path = _find_default_catalog_path()
        if isinstance(api_base_url, str):
            self.api_base_url = api_base_url
        if isinstance(api_key, str):
            self.api_key = api_key
        if isinstance(desired_model, str) and desired_model:
            self.desired_model = desired_model
        self.ab_fallback_timeout_seconds = _parse_timeout_seconds(
            ab_fallback_timeout_seconds,
            DEFAULT_AB_FALLBACK_TIMEOUT_SECONDS,
        )
        self.enable_i18n = _parse_bool(enable_i18n, DEFAULT_ENABLE_I18N)
        if isinstance(locale_source, str) and locale_source.strip():
            normalized_locale_source = locale_source.strip().upper()
            if normalized_locale_source in STATSIG_LOCALE_SOURCE_VALUES:
                self.locale_source = normalized_locale_source
            else:
                _log(
                    "error",
                    "[codex-patch] Invalid locale_source="
                    f"{locale_source}; using {DEFAULT_LOCALE_SOURCE}",
                )
        if isinstance(upstream_proxy, str):
            self.upstream_proxy = upstream_proxy.strip()
            try:
                self.upstream_via = _parse_upstream_proxy(self.upstream_proxy)
            except ValueError as exc:
                self.upstream_via = None
                _log("error", f"[codex-patch] Invalid upstream_proxy: {exc}")

        _log(
            "info",
            f"[codex-patch] Config loaded: model_source={self.model_source}, "
            f"catalog_json={self.catalog_path}, "
            f"api_base_url={self.api_base_url or '<unset>'}, "
            f"desired_model={self.desired_model}, "
            f"upstream_proxy={self.upstream_proxy or '<direct>'}, "
            f"ab_fallback_timeout_seconds={self.ab_fallback_timeout_seconds}, "
            f"enable_i18n={_compact_value(self.enable_i18n)}, "
            f"locale_source={self.locale_source}",
        )

    def _apply_runtime_options(self) -> None:
        options = getattr(ctx, "options", None)
        if options is None or not hasattr(options, "update"):
            return

        updates: dict[str, Any] = {"connection_strategy": "lazy"}
        if self.ab_fallback_timeout_seconds > 0:
            updates["tcp_timeout"] = self.ab_fallback_timeout_seconds
        options.update(**updates)

    def _load_model_sources(self) -> None:
        models: list[dict[str, Any]] = []
        source = self.model_source.lower()

        if source in ("catalog_json", "both"):
            models.extend(self._load_catalog_models())
        if source in ("api", "both"):
            models.extend(self._load_api_models())
        if source not in ("catalog_json", "api", "both"):
            _log(
                "error",
                f"[codex-patch] Unknown model_source={self.model_source}; "
                "falling back to catalog_json",
            )
            models.extend(self._load_catalog_models())

        clean_models, slugs = self._dedupe_models(models)
        if self.desired_model not in slugs:
            clean_models.append(
                {
                    "slug": self.desired_model,
                    "id": self.desired_model,
                    "object": "model",
                    "created": 0,
                    "owned_by": "openai",
                }
            )
            slugs.append(self.desired_model)
            _log(
                "warn",
                f"[codex-patch] desired_model={self.desired_model} is not in "
                "loaded models; using a minimal model row",
            )
        self.catalog_models = clean_models
        self.catalog_slugs = slugs

        _log(
            "info",
            f"[codex-patch] Loaded {len(self.catalog_slugs)} model(s) from "
            f"source={self.model_source}",
        )

    def _resolve_statsig_request(self, flow) -> None:
        timeout = self.ab_fallback_timeout_seconds
        if timeout <= 0:
            return

        request = flow.request
        url = f"https://{STATSIG_HOST}{request.path}"
        data = _read_text(request).encode("utf-8")
        upstream_request = urllib.request.Request(
            url,
            data=data,
            headers=_upstream_request_headers(request.headers),
            method="POST",
        )

        try:
            with self._url_opener().open(upstream_request, timeout=timeout) as response:
                flow.response = http.Response.make(
                    getattr(response, "status", response.getcode()),
                    response.read(),
                    dict(response.headers.items()),
                )
        except urllib.error.HTTPError as exc:
            flow.response = http.Response.make(
                exc.code,
                exc.read(),
                dict(exc.headers.items()) if exc.headers else {},
            )
        except Exception as exc:
            self._set_statsig_fallback_response(
                flow,
                reason=f"request_error:{type(exc).__name__}",
            )
            return

        self._patch_statsig_response(flow, flow.response)

    def _url_opener(self):
        if not self.upstream_proxy:
            return urllib.request.build_opener(urllib.request.ProxyHandler({}))

        proxy = self.upstream_proxy
        if "://" not in proxy:
            proxy = "http://" + proxy
        return urllib.request.build_opener(
            urllib.request.ProxyHandler({"http": proxy, "https": proxy})
        )

    def _load_catalog_models(self) -> list[dict[str, Any]]:
        try:
            with open(self.catalog_path, encoding="utf-8") as f:
                catalog = json.load(f)
        except FileNotFoundError:
            _log("warn", f"[codex-patch] Catalog not found: {self.catalog_path}")
            return []
        except (OSError, json.JSONDecodeError) as exc:
            _log("error", f"[codex-patch] Failed to load catalog {self.catalog_path}: {exc}")
            return []

        models = catalog.get("models") if isinstance(catalog, dict) else catalog
        if not isinstance(models, list):
            _log("error", f"[codex-patch] Catalog has no model list: {self.catalog_path}")
            return []

        _log("info", f"[codex-patch] Read local catalog: {self.catalog_path}")
        return self._normalize_model_rows(models)

    def _load_api_models(self) -> list[dict[str, Any]]:
        if not self.api_base_url:
            _log("error", "[codex-patch] model_source=api but api_base_url is empty")
            return []

        url = _models_url(self.api_base_url)
        headers = {"Accept": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"

        request = urllib.request.Request(url, headers=headers, method="GET")
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                raw = response.read().decode("utf-8")
        except (OSError, urllib.error.URLError) as exc:
            _log("error", f"[codex-patch] Failed to fetch API models from {url}: {exc}")
            return []

        try:
            payload = json.loads(raw)
        except json.JSONDecodeError as exc:
            _log("error", f"[codex-patch] API models response is not JSON: {exc}")
            return []

        if isinstance(payload, dict) and "error" in payload:
            _log("error", f"[codex-patch] API models endpoint returned error from {url}")
            return []

        rows = self._extract_model_rows(payload)
        _log("info", f"[codex-patch] Fetched {len(rows)} API model row(s) from {url}")
        return self._normalize_model_rows(rows)

    @staticmethod
    def _extract_model_rows(payload: Any) -> list[Any]:
        if isinstance(payload, dict):
            data = payload.get("data")
            if isinstance(data, list):
                return data
            models = payload.get("models")
            if isinstance(models, list):
                return models
        if isinstance(payload, list):
            return payload
        return []

    @staticmethod
    def _normalize_model_rows(models: list[Any]) -> list[dict[str, Any]]:
        clean_models: list[dict[str, Any]] = []
        for item in models:
            if not isinstance(item, dict):
                continue
            slug = item.get("slug") or item.get("id")
            if not isinstance(slug, str) or not slug:
                continue
            model = deepcopy(item)
            model.setdefault("slug", slug)
            if "id" in item:
                model.setdefault("id", slug)
            clean_models.append(model)
        return clean_models

    @staticmethod
    def _dedupe_models(models: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], list[str]]:
        clean_models: list[dict[str, Any]] = []
        slugs: list[str] = []
        for model in models:
            slug = model.get("slug") or model.get("id")
            if not isinstance(slug, str) or not slug or slug in slugs:
                continue
            normalized = deepcopy(model)
            normalized.setdefault("slug", slug)
            clean_models.append(normalized)
            slugs.append(slug)
        return clean_models, slugs

    def _patch_models_response(self, request, response) -> None:
        status = getattr(response, "status_code", "<unknown>")
        if not self.catalog_models:
            _log("error", "[codex-patch] Skip /models patch: catalog is empty")
            return

        body = self._read_json_response(response)
        if body is None:
            _log(
                "error",
                f"[codex-patch] Models response patch failed: host={getattr(request, 'pretty_host', request.host)} "
                f"path={_request_path(request)} status={status} reason=not_json",
            )
            return

        changed = False
        if isinstance(body, dict) and isinstance(body.get("data"), list):
            changed = self._patch_model_array(body["data"], mode="openai")
        elif isinstance(body, dict) and isinstance(body.get("models"), list):
            changed = self._patch_model_array(body["models"], mode="native")
        elif isinstance(body, list):
            changed = self._patch_model_array(body, mode="native")

        after_summary = self._models_body_summary(body)
        if not changed:
            _log(
                "error",
                f"[codex-patch] Models response patch no-op: host={getattr(request, 'pretty_host', request.host)} "
                f"path={_request_path(request)} status={status} {after_summary}",
            )
            return

        response.set_text(json.dumps(body, ensure_ascii=False, separators=(",", ":")))
        _remove_stale_headers(response.headers)
        _log(
            "error",
            f"[codex-patch] Models response patched: host={getattr(request, 'pretty_host', request.host)} "
            f"path={_request_path(request)} status={status} {after_summary}",
        )

    def _patch_model_array(self, rows: list[Any], mode: str) -> bool:
        existing = {_model_id(row) for row in rows}
        existing.discard(None)

        added = 0
        for model in self.catalog_models:
            slug = model["slug"]
            if slug in existing:
                continue
            rows.append(_openai_model_from_catalog(model) if mode == "openai" else deepcopy(model))
            existing.add(slug)
            added += 1

        return added > 0

    def _patch_statsig_response(self, flow, response) -> None:
        if not flow.metadata.get("codex_patch_statsig_initialize") and not _is_statsig_initialize(flow.request):
            return

        status = getattr(response, "status_code", 0)
        if isinstance(status, int) and status >= 500:
            self._set_statsig_fallback_response(flow, reason=f"status_{status}")
            return

        body = self._read_json_response(response)
        if body is None or not isinstance(body, dict):
            _log(
                "error",
                f"[codex-patch] AB response patch failed: host={getattr(flow.request, 'pretty_host', flow.request.host)} "
                f"path={_request_path(flow.request)} reason=not_json_object",
            )
            return

        changed = self._patch_statsig_dynamic_configs(body)
        self._patch_statsig_layer_configs(body)
        after = self._statsig_body_summary(body)

        if not changed:
            _log(
                "error",
                f"[codex-patch] AB response patch failed: host={getattr(flow.request, 'pretty_host', flow.request.host)} "
                f"path={_request_path(flow.request)} {after}",
            )
            return
        # Normalize hash_used to "none" so injected plaintext dynamic/layer
        # config keys are found by the Statsig SDK.
        body["hash_used"] = "none"

        self._save_statsig_snapshot(body)

        response.set_text(json.dumps(body, ensure_ascii=False, separators=(",", ":")))

        _remove_stale_headers(response.headers)
        _log(
            "error",
            f"[codex-patch] AB response patched: host={getattr(flow.request, 'pretty_host', flow.request.host)} "
            f"path={_request_path(flow.request)} {after}",
        )

    def _read_json_response(self, response) -> Any | None:
        content_type = response.headers.get("content-type", "")
        if "json" not in content_type.lower():
            return None
        try:
            return json.loads(_read_text(response))
        except (ValueError, TypeError) as exc:
            _log("warn", f"[codex-patch] Could not parse JSON response: {exc}")
            return None

    def _models_body_summary(self, body: Any) -> str:
        rows: list[Any] | None = None
        shape = type(body).__name__
        if isinstance(body, dict) and isinstance(body.get("data"), list):
            rows = body["data"]
            shape = "openai_data"
        elif isinstance(body, dict) and isinstance(body.get("models"), list):
            rows = body["models"]
            shape = "native_models"
        elif isinstance(body, list):
            rows = body
            shape = "list"

        all_ids = {_model_id(row) for row in rows} if rows is not None else set()
        all_ids.discard(None)
        count = len(rows) if rows is not None else "unknown"
        desired_present = self.desired_model in all_ids
        return (
            f"shape={shape} count={count} "
            f"desired_present={_compact_value(desired_present)} "
            f"loaded_models={len(self.catalog_models)}"
        )

    def _statsig_body_summary(self, body: dict[str, Any]) -> str:
        dynamic_configs = body.get("dynamic_configs")
        if not isinstance(dynamic_configs, dict):
            return f"dynamic_configs_type={type(dynamic_configs).__name__}"

        parts = [f"dynamic_configs={len(dynamic_configs)}"]
        layer_configs = body.get("layer_configs")
        if isinstance(layer_configs, dict):
            parts.append(f"layer_configs={len(layer_configs)}")

        missing: list[str] = []
        for key in STATSIG_DYNAMIC_CONFIG_KEYS:
            entry = dynamic_configs.get(key)
            target = self._statsig_entry_summary(body, entry)
            if not target.get("present"):
                missing.append(key)
                continue
            target_parts = [
                f"shape:{target.get('shape', '<none>')}",
                f"default:{_compact_value(target.get('default_model'))}",
                f"desired:{_compact_value(target.get('desired_present'))}",
            ]
            if target.get("available_count") is not None:
                target_parts.append(f"available:{target['available_count']}")
            if target.get("use_hidden_models") is not None:
                target_parts.append(f"hidden:{_compact_value(target['use_hidden_models'])}")
            parts.append(f"{key}=" + ",".join(target_parts))
        if missing:
            parts.append("missing=" + ",".join(missing))

        i18n = self._i18n_layer_summary(body)
        if i18n.get("present"):
            parts.append(
                f"{STATSIG_I18N_LAYER_CONFIG_KEY}=shape:{i18n.get('shape', '<none>')},"
                f"i18n:{_compact_value(i18n.get('enable_i18n'))},"
                f"source:{_compact_value(i18n.get('locale_source'))}"
            )
        else:
            parts.append(f"missing_layer={STATSIG_I18N_LAYER_CONFIG_KEY}")
        return " ".join(parts)

    def _ensure_snapshot_dir(self) -> None:
        if self._snapshot_dir_ensured:
            return
        path = _statsig_snapshot_dir()
        try:
            os.makedirs(path, exist_ok=True)
            self._snapshot_dir_ensured = True
        except OSError as exc:
            _log("error", f"[codex-patch] Failed to create snapshot dir {path}: {exc}")

    def _save_statsig_snapshot(self, body: dict[str, Any]) -> None:
        self._ensure_snapshot_dir()
        path = _statsig_snapshot_path()
        try:
            with open(path, "w", encoding="utf-8") as f:
                json.dump(body, f, ensure_ascii=False, separators=(",", ":"))
        except OSError as exc:
            _log("error", f"[codex-patch] Failed to save Statsig snapshot to {path}: {exc}")

    def _load_statsig_snapshot_or_template(self) -> dict[str, Any] | None:
        snapshot_path = _statsig_snapshot_path()
        template_path = _statsig_init_template_path()

        if not os.path.isfile(snapshot_path):
            if os.path.isfile(template_path):
                try:
                    self._ensure_snapshot_dir()
                    with open(template_path, encoding="utf-8") as src:
                        template_body = json.load(src)
                    if not isinstance(template_body, dict):
                        raise ValueError("init-template.json is not a JSON object")
                    with open(snapshot_path, "w", encoding="utf-8") as dst:
                        json.dump(template_body, dst, ensure_ascii=False, separators=(",", ":"))
                    _log("info", "[codex-patch] Statsig snapshot seeded from init-template.json")
                except (OSError, json.JSONDecodeError, ValueError) as exc:
                    _log("error", f"[codex-patch] Failed to seed snapshot from template: {exc}")
                    return None
            else:
                _log("error", f"[codex-patch] Statsig init-template not found: {template_path}")
                return None

        try:
            with open(snapshot_path, encoding="utf-8") as f:
                body = json.load(f)
            if not isinstance(body, dict):
                raise ValueError("snapshot cache is not a JSON object")
            if body.get("hash_used", "none") != "none":
                _log(
                    "warn",
                    "[codex-patch] Statsig snapshot hash_used="
                    f"{body.get('hash_used')} differs from plaintext key format; "
                    "normalizing to 'none'",
                )
                body["hash_used"] = "none"
            return body
        except (OSError, json.JSONDecodeError, ValueError) as exc:
            _log("error", f"[codex-patch] Failed to load Statsig snapshot {snapshot_path}: {exc}")
            return None

    def _build_statsig_fallback_body(self) -> dict[str, Any]:
        dynamic_configs: dict[str, Any] = {}
        for key in STATSIG_DYNAMIC_CONFIG_KEYS:
            dynamic_configs[key] = self._build_statsig_dynamic_config_entry(key)

        layer_configs = {
            STATSIG_I18N_LAYER_CONFIG_KEY: self._build_i18n_layer_entry({}),
        }

        return {
            "feature_gates": {},
            "dynamic_configs": dynamic_configs,
            "layer_configs": layer_configs,
            "sdkParams": {},
            "has_updates": True,
            "generator": "codex-model-bridge",
            "time": int(time.time() * 1000),
            "company_lcut": 0,
            "evaluated_keys": {},
            "hash_used": "none",
            "derived_fields": {},
            "hashed_sdk_key_used": None,
            "can_record_session": False,
            "recording_blocked": True,
            "session_recording_rate": 0,
            "param_stores": {},
            "sdk_flags": {},
            "target_app_used": "codex-model-bridge",
            "full_checksum": "codex-model-bridge-fallback",
        }

    def _set_statsig_fallback_response(self, flow, reason: str) -> None:
        body = self._load_statsig_snapshot_or_template()
        if body is not None:
            self._patch_statsig_dynamic_configs(body)
            self._patch_statsig_layer_configs(body)
            body["time"] = int(time.time() * 1000)
            body["hash_used"] = "none"
        else:
            body = self._build_statsig_fallback_body()
        flow.response = http.Response.make(
            200,
            json.dumps(body, ensure_ascii=False, separators=(",", ":")),
            FALLBACK_RESPONSE_HEADERS,
        )
        flow.error = None
        request = flow.request
        _log(
            "error",
            f"[codex-patch] AB fallback response built: host={getattr(request, 'pretty_host', request.host)} "
            f"path={_request_path(request)} reason={reason} {self._statsig_body_summary(body)}",
        )

    def _statsig_entry_summary(self, body: dict[str, Any], entry: Any) -> dict[str, Any]:
        if not isinstance(entry, dict):
            return {"present": False}

        value = entry.get("value")
        shape = "value" if isinstance(value, dict) else None
        if not isinstance(value, dict):
            ref = entry.get("v")
            values = body.get("values")
            if isinstance(values, list) and isinstance(ref, int) and 0 <= ref < len(values):
                value = values[ref]
                shape = "compact"

        result: dict[str, Any] = {
            "present": True,
            "shape": shape or "unknown",
        }
        if isinstance(value, dict):
            available = value.get("available_models")
            result.update(
                {
                    "available_count": len(available)
                    if isinstance(available, list)
                    else None,
                    "desired_present": self.desired_model in available
                    if isinstance(available, list)
                    else False,
                    "use_hidden_models": value.get("use_hidden_models"),
                    "default_model": value.get("default_model"),
                }
            )
        return result

    def _i18n_layer_summary(self, body: dict[str, Any]) -> dict[str, Any]:
        layer_configs = body.get("layer_configs")
        if not isinstance(layer_configs, dict):
            return {"present": False}

        entry = layer_configs.get(STATSIG_I18N_LAYER_CONFIG_KEY)
        if not isinstance(entry, dict):
            return {"present": False}

        value = entry.get("value")
        shape = "value" if isinstance(value, dict) else None
        if not isinstance(value, dict):
            ref = entry.get("v")
            values = body.get("values")
            if isinstance(values, list) and isinstance(ref, int) and 0 <= ref < len(values):
                value = values[ref]
                shape = "compact"

        result: dict[str, Any] = {
            "present": True,
            "shape": shape or "unknown",
        }
        if isinstance(value, dict):
            result.update(
                {
                    "enable_i18n": value.get("enable_i18n"),
                    "locale_source": value.get("locale_source"),
                }
            )
        return result

    def _patch_statsig_dynamic_configs(self, body: dict[str, Any]) -> bool:
        dynamic_configs = body.get("dynamic_configs")
        if not isinstance(dynamic_configs, dict):
            _log("error", "[codex-patch] Statsig response has no dynamic_configs object")
            return False

        changed = False
        for key in STATSIG_DYNAMIC_CONFIG_KEYS:
            entry = dynamic_configs.get(key)
            if not isinstance(entry, dict):
                dynamic_configs[key] = self._build_statsig_dynamic_config_entry(key)
                _log("info", f"[codex-patch] Statsig dynamic config key {key} injected (missing in upstream)")
                changed = True
            elif self._patch_statsig_entry(body, entry):
                changed = True

        if not changed:
            _log(
                "error",
                "[codex-patch] Statsig target dynamic config key was not found or "
                "could not be patched",
            )
        return changed

    def _build_statsig_dynamic_config_entry(self, key: str) -> dict[str, Any]:
        return {
            "name": key,
            "value": self._merged_statsig_value({}),
            "rule_id": "codex_model_bridge_fallback",
            "group": "codex_model_bridge_fallback",
            "id_type": "userID",
            "secondary_exposures": [],
            "explicit_parameters": [],
            "is_device_based": False,
            "is_experiment_active": True,
            "is_user_in_experiment": True,
        }

    def _patch_statsig_layer_configs(self, body: dict[str, Any]) -> bool:
        layer_configs = body.get("layer_configs")
        if not isinstance(layer_configs, dict):
            layer_configs = {}
            body["layer_configs"] = layer_configs

        entry = layer_configs.get(STATSIG_I18N_LAYER_CONFIG_KEY)
        if not isinstance(entry, dict):
            layer_configs[STATSIG_I18N_LAYER_CONFIG_KEY] = self._build_i18n_layer_entry({})
            return True

        return self._patch_i18n_layer_entry(body, entry)

    def _patch_statsig_entry(self, body: dict[str, Any], entry: dict[str, Any]) -> bool:
        value = entry.get("value")
        if isinstance(value, dict):
            entry["value"] = self._merged_statsig_value(value)
            return True

        ref = entry.get("v")
        values = body.get("values")
        if isinstance(values, list) and isinstance(ref, int) and 0 <= ref < len(values):
            current = values[ref]
            if isinstance(current, dict):
                values[ref] = self._merged_statsig_value(current)
                return True
        return False

    def _patch_i18n_layer_entry(self, body: dict[str, Any], entry: dict[str, Any]) -> bool:
        self._ensure_explicit_parameters(entry, ("enable_i18n", "locale_source"))

        value = entry.get("value")
        if isinstance(value, dict):
            entry["value"] = self._merged_i18n_layer_value(value)
            return True

        ref = entry.get("v")
        values = body.get("values")
        if isinstance(values, list) and isinstance(ref, int) and 0 <= ref < len(values):
            current = values[ref]
            if isinstance(current, dict):
                values[ref] = self._merged_i18n_layer_value(current)
                return True

        entry.pop("v", None)
        entry["value"] = self._merged_i18n_layer_value({})
        return True

    def _build_i18n_layer_entry(self, existing: dict[str, Any]) -> dict[str, Any]:
        return {
            "name": STATSIG_I18N_LAYER_CONFIG_KEY,
            "value": self._merged_i18n_layer_value(existing),
            "rule_id": "codex_model_bridge_i18n",
            "group": "codex_model_bridge_i18n",
            "id_type": "userID",
            "secondary_exposures": [],
            "undelegated_secondary_exposures": [],
            "explicit_parameters": ["enable_i18n", "locale_source"],
            "is_device_based": False,
            "is_experiment_active": True,
            "is_user_in_experiment": True,
        }

    @staticmethod
    def _ensure_explicit_parameters(entry: dict[str, Any], names: tuple[str, ...]) -> None:
        explicit = entry.get("explicit_parameters")
        if not isinstance(explicit, list):
            explicit = []
        for name in names:
            if name not in explicit:
                explicit.append(name)
        entry["explicit_parameters"] = explicit

    def _merged_statsig_value(self, existing: dict[str, Any]) -> dict[str, Any]:
        merged = deepcopy(existing)
        available = merged.get("available_models")
        if not isinstance(available, list):
            available = []

        seen: set[str] = set()
        result: list[str] = []
        for slug in available + self.catalog_slugs:
            if isinstance(slug, str) and slug and slug not in seen:
                result.append(slug)
                seen.add(slug)

        if self.desired_model not in seen:
            result.append(self.desired_model)

        merged["available_models"] = result
        merged["use_hidden_models"] = True
        merged["default_model"] = self.desired_model
        return merged

    def _merged_i18n_layer_value(self, existing: dict[str, Any]) -> dict[str, Any]:
        merged = deepcopy(existing)
        merged["enable_i18n"] = self.enable_i18n
        merged["locale_source"] = self.locale_source
        return merged


addons = [CodexCatalogPatcher()]

"""mitmproxy addon for Codex model-list and Statsig startup patching.

The network targets are intentionally hardcoded:

- Statsig startup config: ab.chatgpt.com/v1/initialize
- Post-login Statsig config: chatgpt.com/wham/statsig/bootstrap
- Model API source: any Codex-captured request whose path ends in /models

Only local machine differences live in config.json: desired_model and where to
read model rows from. A bundled, sanitized catalog template is included next to
this script so a fresh installation can still enrich API model rows. A
model source can be a local catalog JSON file or a configured OpenAI-compatible
base URL plus API key. Statsig is only used to keep those rows visible and
choose the default model.
"""

from __future__ import annotations

import base64
import hashlib
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
WHAM_STATSIG_HOSTS = ("chatgpt.com", "chat.openai.com")
WHAM_STATSIG_PATH = "/wham/statsig/bootstrap"
STATSIG_DYNAMIC_CONFIG_KEYS = ("107580212", "2523198654")
STATSIG_I18N_LAYER_CONFIG_KEY = "72216192"
STATSIG_LOCALE_SOURCE_VALUES = ("IDE", "SYSTEM", "FIRST_AVAILABLE")

DEFAULT_DESIRED_MODEL = "gpt-5.5"
DEFAULT_MODEL_SOURCE = "catalog_json"
DEFAULT_UPSTREAM_PROXY = ""
DEFAULT_AB_FALLBACK_TIMEOUT_SECONDS = 8
DEFAULT_ENABLE_I18N = True
DEFAULT_LOCALE_SOURCE = "FIRST_AVAILABLE"
# Avoid WAF rules that reject urllib's default Python browser signature.
MODEL_API_USER_AGENT = "CodexModelBridge/1.0"
DEFAULT_INPUT_MODALITIES = ("text",)
SUPPORTED_INPUT_MODALITIES = frozenset({"text", "image", "audio"})

STALE_HEADERS = ("content-length", "etag", "last-modified", "content-md5")
MODEL_INTERNAL_KEYS = frozenset({"_source_fields"})
MODEL_SOURCE_ONLY_KEYS = frozenset(
    {
        "id",
        "object",
        "created",
        "owned_by",
        "name",
        "provider",
    }
)
NATIVE_MODEL_SIGNATURE_KEYS = (
    "slug",
    "display_name",
    "supported_reasoning_levels",
    "shell_type",
    "visibility",
    "base_instructions",
)
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
BUNDLED_CATALOG_FILENAME = "models_catalog.template.json"
RUNTIME_BUNDLED_CATALOG_ENV = "CODEX_MODEL_BRIDGE_BUNDLED_CATALOG"
RUNTIME_CATALOG_ENV = "CODEX_MODEL_BRIDGE_RUNTIME_CATALOG"
RUNTIME_CATALOG_META_ENV = "CODEX_MODEL_BRIDGE_RUNTIME_META"
RUNTIME_GENERATION_ENV = "CODEX_MODEL_BRIDGE_RUNTIME_GENERATION"


def _resolve_config_path(value: str) -> str:
    expanded = os.path.expanduser(value)
    if os.path.isabs(expanded):
        return expanded
    return os.path.join(os.path.dirname(_config_path()), expanded)


def _default_catalog_candidates() -> tuple[str, ...]:
    candidates = (
        os.path.join(os.path.dirname(_config_path()), "models_catalog.json"),
        os.path.join(_script_dir(), BUNDLED_CATALOG_FILENAME),
    )
    return tuple(dict.fromkeys(candidates))


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


def _is_wham_statsig_bootstrap(request) -> bool:
    path = _request_path(request).rstrip("/")
    return (
        request.method.upper() == "POST"
        and any(_request_matches_host(request, host) for host in WHAM_STATSIG_HOSTS)
        and path.endswith(WHAM_STATSIG_PATH)
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
    value = model.get("slug") or model.get("id") or model.get("name")
    return value if isinstance(value, str) and value else None


def _model_display_name(model: dict[str, Any], slug: str) -> str:
    for key in ("display_name", "name"):
        value = model.get(key)
        if isinstance(value, str) and value:
            return value
    return slug


def _model_source_fields(model: dict[str, Any]) -> set[str]:
    fields = model.get("_source_fields")
    if isinstance(fields, (list, tuple, set, frozenset)):
        return {field for field in fields if isinstance(field, str)}
    return {key for key in model if key not in MODEL_INTERNAL_KEYS}


def _synchronize_reasoning_summary_fields(model: dict[str, Any]) -> None:
    """Keep the legacy and current catalog field names semantically aligned."""
    current = model.get("supports_reasoning_summary_parameter")
    legacy = model.get("supports_reasoning_summaries")

    if isinstance(current, bool):
        # The current Codex schema is authoritative when both names exist.
        model["supports_reasoning_summaries"] = current
    elif isinstance(legacy, bool):
        model["supports_reasoning_summary_parameter"] = legacy


def _input_modalities_or_default(model: dict[str, Any]) -> list[str]:
    modalities = model.get("input_modalities")
    if isinstance(modalities, list):
        normalized: list[str] = []
        for item in modalities:
            if (
                isinstance(item, str)
                and item in SUPPORTED_INPUT_MODALITIES
                and item not in normalized
            ):
                normalized.append(item)
        if normalized:
            return normalized
    return list(DEFAULT_INPUT_MODALITIES)


def _looks_like_openai_model(model: Any) -> bool:
    if not isinstance(model, dict):
        return False
    model_id = model.get("id")
    if not isinstance(model_id, str) or not model_id:
        return False
    return any(key in model for key in ("object", "created", "owned_by"))


def _looks_like_native_model(model: Any) -> bool:
    if not isinstance(model, dict):
        return False
    if not all(key in model for key in NATIVE_MODEL_SIGNATURE_KEYS):
        return False
    return (
        isinstance(model.get("slug"), str)
        and bool(model["slug"])
        and isinstance(model.get("display_name"), str)
        and isinstance(model.get("supported_reasoning_levels"), list)
        and isinstance(model.get("shell_type"), str)
        and isinstance(model.get("visibility"), str)
        and isinstance(model.get("base_instructions"), str)
    )


def _default_native_model(slug: str, display_name: str) -> dict[str, Any]:
    return {
        "slug": slug,
        "display_name": display_name,
        "description": None,
        "default_reasoning_level": None,
        "supported_reasoning_levels": [],
        "shell_type": "default",
        "visibility": "list",
        "minimal_client_version": [0, 0, 0],
        "supported_in_api": True,
        "priority": 99,
        "additional_speed_tiers": [],
        "service_tiers": [],
        "default_service_tier": None,
        "availability_nux": None,
        "upgrade": None,
        "base_instructions": "You are Codex, a coding agent.",
        "model_messages": None,
        "include_skills_usage_instructions": False,
        "supports_reasoning_summary_parameter": True,
        # Older catalogs used this field name; keep both defaults aligned.
        "supports_reasoning_summaries": True,
        "default_reasoning_summary": "auto",
        "support_verbosity": False,
        "default_verbosity": None,
        "apply_patch_tool_type": None,
        "web_search_tool_type": "text",
        "truncation_policy": {"mode": "bytes", "limit": 10_000},
        "supports_parallel_tool_calls": False,
        "supports_image_detail_original": False,
        "context_window": 272_000,
        "max_context_window": 272_000,
        "auto_compact_token_limit": None,
        "comp_hash": None,
        "effective_context_window_percent": 95,
        "experimental_supported_tools": [],
        "input_modalities": list(DEFAULT_INPUT_MODALITIES),
        "supports_search_tool": False,
        "use_responses_lite": False,
        "auto_review_model_override": None,
        "tool_mode": None,
        "multi_agent_version": None,
    }


def _openai_model_from_catalog(model: dict[str, Any]) -> dict[str, Any]:
    slug = _model_id(model)
    if slug is None:
        return {}

    object_name = model.get("object")
    if not isinstance(object_name, str) or not object_name:
        object_name = "model"

    created = model.get("created")
    if isinstance(created, bool) or not isinstance(created, (int, float)):
        created = 0
    else:
        created = int(created)

    owned_by = model.get("owned_by") or model.get("provider")
    if not isinstance(owned_by, str) or not owned_by:
        owned_by = "openai"

    row = {
        "id": slug,
        "object": object_name,
        "created": created,
        "owned_by": owned_by,
    }

    display_name = _model_display_name(model, slug)
    if display_name != slug:
        row["display_name"] = display_name
    return row


def _models_url(base_url: str) -> str:
    return base_url.rstrip("/") + "/models"


def _http_error_summary(raw: bytes) -> str:
    try:
        payload = json.loads(raw.decode("utf-8", "replace"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return ""

    if not isinstance(payload, dict):
        return ""

    details: dict[str, Any] = {}
    error = payload.get("error")
    if isinstance(error, dict):
        for key in ("message", "type", "code"):
            if key not in error:
                continue
            value = error[key]
            if isinstance(value, str):
                details[key] = value[:500]
            elif isinstance(value, (int, float, bool)) or value is None:
                details[key] = value
    else:
        for key in (
            "title",
            "detail",
            "error_code",
            "error_name",
            "retryable",
            "cloudflare_error",
        ):
            if key not in payload:
                continue
            value = payload[key]
            if isinstance(value, str):
                details[key] = value[:500]
            elif isinstance(value, (int, float, bool)) or value is None:
                details[key] = value

    if not details:
        return ""
    return " response=" + json.dumps(
        details,
        ensure_ascii=False,
        separators=(",", ":"),
    )


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
        self.runtime_bundled_catalog_path = os.environ.get(
            RUNTIME_BUNDLED_CATALOG_ENV,
            "",
        )
        self.runtime_catalog_path = os.environ.get(RUNTIME_CATALOG_ENV, "")
        self.runtime_catalog_meta_path = os.environ.get(
            RUNTIME_CATALOG_META_ENV,
            "",
        )
        self.runtime_generation = os.environ.get(RUNTIME_GENERATION_ENV, "")
        self.api_models_fetch_succeeded = False
        self.api_model_ids: set[str] = set()
        self.runtime_bundled_models: list[dict[str, Any]] = []
        self.metadata_models: list[dict[str, Any]] = []
        self.metadata_slugs: list[str] = []
        self.catalog_models: list[dict[str, Any]] = []
        self.catalog_slugs: list[str] = []
        self.catalog_by_slug: dict[str, dict[str, Any]] = {}
        self._snapshot_dir_ensured = False

    def load(self, loader) -> None:
        self._load_config()
        self._apply_runtime_options()
        self._load_model_sources()
        self._write_runtime_catalog_if_requested()

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
        _log(
            "error",
            f"[codex-patch] AB TLS client established: hosts={_context_hosts(data.context)}",
        )

    def tls_failed_client(self, data) -> None:
        if not _context_matches_host(data.context, STATSIG_HOST):
            return
        _log(
            "error",
            f"[codex-patch] AB TLS client failed: hosts={_context_hosts(data.context)}",
        )

    def tls_failed_server(self, data) -> None:
        if not _context_matches_host(data.context, STATSIG_HOST):
            return
        _log(
            "error",
            f"[codex-patch] AB TLS server failed: hosts={_context_hosts(data.context)}",
        )

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

        request.set_text(
            _encode_se(body) if encoded else json.dumps(body, ensure_ascii=False)
        )
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

        if _is_wham_statsig_bootstrap(request):
            self._patch_wham_statsig_response(request, response)
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
            _log("warn", f"[codex-patch] Failed to load config {path}: {exc}")

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
                    "warn",
                    "[codex-patch] Invalid locale_source="
                    f"{locale_source}; using {DEFAULT_LOCALE_SOURCE}",
                )
        if isinstance(upstream_proxy, str):
            self.upstream_proxy = upstream_proxy.strip()
            try:
                self.upstream_via = _parse_upstream_proxy(self.upstream_proxy)
            except ValueError as exc:
                self.upstream_via = None
                _log("warn", f"[codex-patch] Invalid upstream_proxy: {exc}")

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

        # The AB fallback timeout belongs only to the explicit urllib request in
        # _resolve_statsig_request. Applying it as mitmproxy's global TCP idle
        # timeout would terminate quiet long-running Responses API streams.
        options.update(connection_strategy="lazy")

    def _load_model_sources(self) -> None:
        models: list[dict[str, Any]] = []
        source = self.model_source.lower()
        catalog_models = self._load_catalog_models()
        self.runtime_bundled_models = self._load_runtime_bundled_models()
        bundled_template_models = self._load_bundled_template_models()
        bundled_template_path = os.path.abspath(
            os.path.join(_script_dir(), BUNDLED_CATALOG_FILENAME)
        )
        if os.path.abspath(self.catalog_path) == bundled_template_path:
            metadata_sources = catalog_models + self.runtime_bundled_models
        else:
            metadata_sources = (
                catalog_models
                + bundled_template_models
                + self.runtime_bundled_models
            )
        metadata_models, metadata_slugs = self._dedupe_models(
            metadata_sources
        )
        self.metadata_models = metadata_models
        self.metadata_slugs = metadata_slugs

        if source in ("catalog_json", "both"):
            models.extend(catalog_models)
        if source in ("api", "both"):
            api_models = self._load_api_models()
            self.api_model_ids = {
                slug
                for slug in (_model_id(model) for model in api_models)
                if slug is not None
            }
            if api_models:
                models.extend(
                    self._enrich_model_metadata(api_models, metadata_models)
                )
            elif source == "api":
                models.extend(self._load_previous_runtime_models())
        else:
            self.api_model_ids = set()
        if source not in ("catalog_json", "api", "both"):
            _log(
                "warn",
                f"[codex-patch] Unknown model_source={self.model_source}; "
                "falling back to catalog_json",
            )
            models.extend(catalog_models)

        clean_models, slugs = self._dedupe_models(models)
        if self.desired_model not in slugs:
            desired_aliases = {
                self.desired_model,
                self.desired_model.rsplit("/", 1)[-1],
            }
            alias_matches: list[str] = []
            for model in clean_models:
                slug = _model_id(model)
                if slug is None:
                    continue
                if desired_aliases.intersection(self._model_aliases(model)):
                    alias_matches.append(slug)
            if len(alias_matches) == 1:
                configured_model = self.desired_model
                self.desired_model = alias_matches[0]
                _log(
                    "info",
                    "[codex-patch] Resolved desired_model alias "
                    f"{configured_model} -> {self.desired_model}",
                )

        if self.desired_model not in slugs and source == "api":
            if clean_models:
                configured_model = self.desired_model
                self.desired_model = slugs[0]
                _log(
                    "warn",
                    f"[codex-patch] desired_model={configured_model} is not "
                    f"returned by the model API; using {self.desired_model} "
                    "as the runtime default without injecting an extra "
                    "catalog row",
                )
            else:
                _log(
                    "warn",
                    "[codex-patch] No API or previous runtime model IDs are "
                    "available; refusing to populate the runtime catalog "
                    "from metadata templates",
                )
        elif self.desired_model not in slugs:
            desired_rows = self._normalize_model_rows(
                [
                    {
                        "slug": self.desired_model,
                        "name": self.desired_model.rsplit("/", 1)[-1],
                    }
                ]
            )
            desired_models = self._enrich_model_metadata(
                desired_rows,
                metadata_models,
                log_result=False,
            )
            clean_models.extend(desired_models)
            slugs.append(self.desired_model)
            _log(
                "warn",
                f"[codex-patch] desired_model={self.desired_model} is not in "
                "loaded models; injecting a catalog-backed fallback row",
            )
        self.catalog_models = clean_models
        self.catalog_slugs = slugs
        self.catalog_by_slug = {
            model["slug"]: model
            for model in clean_models
            if isinstance(model.get("slug"), str)
        }

        _log(
            "info",
            f"[codex-patch] Loaded {len(self.catalog_slugs)} model(s) from "
            f"source={self.model_source}; "
            f"metadata_templates={len(self.metadata_slugs)}",
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
        return self._load_catalog_models_from_path(self.catalog_path, "local catalog")

    def _load_bundled_template_models(self) -> list[dict[str, Any]]:
        path = os.path.join(_script_dir(), BUNDLED_CATALOG_FILENAME)
        if os.path.abspath(path) == os.path.abspath(self.catalog_path):
            return []
        return self._load_catalog_models_from_path(path, "bundled metadata template")

    def _load_catalog_models_from_path(
        self,
        path: str,
        label: str,
    ) -> list[dict[str, Any]]:
        try:
            with open(path, encoding="utf-8") as f:
                catalog = json.load(f)
        except FileNotFoundError:
            _log("warn", f"[codex-patch] Catalog not found: {path}")
            return []
        except (OSError, json.JSONDecodeError) as exc:
            _log(
                "warn",
                f"[codex-patch] Failed to load catalog {path}: {exc}",
            )
            return []

        models = catalog.get("models") if isinstance(catalog, dict) else catalog
        if not isinstance(models, list):
            _log("warn", f"[codex-patch] Catalog has no model list: {path}")
            return []

        _log("info", f"[codex-patch] Read {label}: {path}")
        return self._normalize_model_rows(models)

    def _load_api_models(self) -> list[dict[str, Any]]:
        self.api_models_fetch_succeeded = False
        if not self.api_base_url:
            _log("warn", "[codex-patch] model_source=api but api_base_url is empty")
            return []

        url = _models_url(self.api_base_url)
        headers = {
            "Accept": "application/json",
            "User-Agent": MODEL_API_USER_AGENT,
        }
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"

        request = urllib.request.Request(url, headers=headers, method="GET")
        try:
            with self._url_opener().open(request, timeout=10) as response:
                raw = response.read().decode("utf-8")
        except urllib.error.HTTPError as exc:
            summary = _http_error_summary(exc.read(4096))
            _log(
                "warn",
                f"[codex-patch] Failed to fetch API models from {url}: "
                f"HTTP {exc.code} {exc.reason}{summary}",
            )
            return []
        except (OSError, urllib.error.URLError) as exc:
            _log("warn", f"[codex-patch] Failed to fetch API models from {url}: {exc}")
            return []

        try:
            payload = json.loads(raw)
        except json.JSONDecodeError as exc:
            _log("warn", f"[codex-patch] API models response is not JSON: {exc}")
            return []

        if isinstance(payload, dict) and "error" in payload:
            _log("warn", f"[codex-patch] API models endpoint returned error from {url}")
            return []

        rows = self._extract_model_rows(payload)
        normalized = self._normalize_model_rows(rows)
        unique_models, unique_ids = self._dedupe_models(normalized)
        self.api_models_fetch_succeeded = bool(unique_models)
        if not unique_models:
            _log(
                "warn",
                f"[codex-patch] API models endpoint returned no model rows: {url}",
            )
        _log(
            "info",
            f"[codex-patch] Fetched {len(rows)} API model row(s), "
            f"{len(unique_ids)} unique model ID(s) from {url}",
        )
        return unique_models

    def _load_runtime_bundled_models(self) -> list[dict[str, Any]]:
        path = self.runtime_bundled_catalog_path
        if not path:
            return []

        try:
            with open(path, encoding="utf-8") as f:
                catalog = json.load(f)
        except FileNotFoundError:
            _log("warn", f"[codex-patch] Bundled runtime catalog not found: {path}")
            return []
        except (OSError, json.JSONDecodeError) as exc:
            _log(
                "warn",
                f"[codex-patch] Failed to load bundled runtime catalog {path}: {exc}",
            )
            return []

        rows = self._extract_model_rows(catalog)
        models = [
            deepcopy(row)
            for row in rows
            if isinstance(row, dict) and _looks_like_native_model(row)
        ]
        _log(
            "info",
            f"[codex-patch] Read {len(models)} bundled runtime model(s): {path}",
        )
        return models

    @staticmethod
    def _runtime_native_model(model: dict[str, Any]) -> dict[str, Any]:
        row = deepcopy(model)
        for key in MODEL_INTERNAL_KEYS | MODEL_SOURCE_ONLY_KEYS:
            row.pop(key, None)

        slug = _model_id(row)
        if slug is None:
            return {}

        display_name = _model_display_name(row, slug)
        defaults = _default_native_model(slug, display_name)
        for key, value in defaults.items():
            row.setdefault(key, deepcopy(value))
        _synchronize_reasoning_summary_fields(row)
        row.pop("supports_reasoning_summaries", None)
        row["slug"] = slug
        row["display_name"] = display_name
        row["input_modalities"] = _input_modalities_or_default(row)
        return row

    def _runtime_catalog_models(self) -> list[dict[str, Any]]:
        result: list[dict[str, Any]] = []
        seen: set[str] = set()

        source = self.model_source.lower()
        if source in ("api", "both") and not self.api_models_fetch_succeeded:
            for model in self._load_previous_runtime_models():
                slug = _model_id(model)
                if slug is None or slug in seen:
                    continue
                result.append(deepcopy(model))
                seen.add(slug)

        for model in self.catalog_models:
            slug = _model_id(model)
            if slug is None or slug in seen:
                continue
            row = self._runtime_native_model(model)
            if not row:
                continue
            row["visibility"] = "list"
            row["supported_in_api"] = True
            result.append(row)
            seen.add(slug)

        return result

    def _load_previous_runtime_models(self) -> list[dict[str, Any]]:
        path = self.runtime_catalog_path
        if not path:
            return []

        try:
            with open(path, encoding="utf-8") as f:
                catalog = json.load(f)
        except (FileNotFoundError, OSError, json.JSONDecodeError):
            return []

        rows = self._extract_model_rows(catalog)
        models, _ = self._dedupe_models(
            [
                deepcopy(row)
                for row in rows
                if isinstance(row, dict) and _looks_like_native_model(row)
            ]
        )
        if models:
            _log(
                "warn",
                "[codex-patch] API models unavailable; reusing "
                f"{len(models)} row(s) from the same-CLI runtime catalog",
            )
        return models

    @staticmethod
    def _write_json_atomic(path: str, payload: Any) -> None:
        directory = os.path.dirname(path)
        if directory:
            os.makedirs(directory, exist_ok=True)
        temporary_path = path + f".tmp-{os.getpid()}"
        try:
            with open(temporary_path, "w", encoding="utf-8", newline="\n") as f:
                json.dump(
                    payload,
                    f,
                    ensure_ascii=False,
                    separators=(",", ":"),
                )
                f.write("\n")
            os.replace(temporary_path, path)
        finally:
            try:
                os.remove(temporary_path)
            except FileNotFoundError:
                pass

    def _write_runtime_catalog_if_requested(self) -> None:
        if not self.runtime_catalog_path:
            return

        models = self._runtime_catalog_models()
        if not models:
            _log(
                "warn",
                "[codex-patch] Runtime catalog generation skipped: no models available",
            )
            return

        payload = {"models": models}
        try:
            self._write_json_atomic(self.runtime_catalog_path, payload)
            catalog_sha256 = hashlib.sha256(
                json.dumps(
                    payload,
                    ensure_ascii=False,
                    separators=(",", ":"),
                ).encode("utf-8")
            ).hexdigest()
            if self.runtime_catalog_meta_path:
                self._write_json_atomic(
                    self.runtime_catalog_meta_path,
                    {
                        "generation": self.runtime_generation,
                        "api_models_fetch_succeeded": (
                            self.api_models_fetch_succeeded
                        ),
                        "api_model_ids": sorted(self.api_model_ids),
                        "models": len(models),
                        "catalog_sha256": catalog_sha256,
                        "generated_at_unix": int(time.time()),
                    },
                )
        except OSError as exc:
            _log(
                "warn",
                "[codex-patch] Failed to write runtime catalog "
                f"{self.runtime_catalog_path}: {exc}",
            )
            return

        _log(
            "info",
            "[codex-patch] Runtime display catalog written: "
            f"path={self.runtime_catalog_path}, models={len(models)}, "
            f"api_fresh={self.api_models_fetch_succeeded}",
        )

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
            model_id = item.get("id")
            name = item.get("name")
            route_slug = item.get("slug")
            provider = item.get("provider")
            is_mb_row = (
                isinstance(name, str)
                and bool(name)
                and isinstance(route_slug, str)
                and bool(route_slug)
                and (
                    isinstance(provider, str)
                    or (
                        route_slug != name
                        and "/" in route_slug
                    )
                )
            )
            if is_mb_row:
                model_id = name
            elif not isinstance(model_id, str) or not model_id:
                model_id = name if is_mb_row else route_slug or name
            slug = model_id
            if not isinstance(slug, str) or not slug:
                continue
            model = deepcopy(item)
            _synchronize_reasoning_summary_fields(model)
            source_fields = {key for key in item if key not in MODEL_INTERNAL_KEYS}
            if (
                "supports_reasoning_summary_parameter" in model
                or "supports_reasoning_summaries" in model
            ):
                source_fields.update(
                    {
                        "supports_reasoning_summary_parameter",
                        "supports_reasoning_summaries",
                    }
                )
            model["_source_fields"] = tuple(sorted(source_fields))
            model["slug"] = slug
            model["id"] = slug
            model["display_name"] = _model_display_name(model, slug)
            provider = model.get("provider") or model.get("owned_by")
            if isinstance(provider, str) and provider:
                model["provider"] = provider
            clean_models.append(model)
        return clean_models

    @staticmethod
    def _dedupe_models(
        models: list[dict[str, Any]],
    ) -> tuple[list[dict[str, Any]], list[str]]:
        clean_models: list[dict[str, Any]] = []
        slugs: list[str] = []
        for model in models:
            slug = _model_id(model)
            if not isinstance(slug, str) or not slug or slug in slugs:
                continue
            normalized = deepcopy(model)
            normalized["slug"] = slug
            normalized["id"] = slug
            clean_models.append(normalized)
            slugs.append(slug)
        return clean_models, slugs

    @staticmethod
    def _model_aliases(model: dict[str, Any]) -> list[str]:
        aliases: list[str] = []
        for key in ("slug", "id", "name"):
            value = model.get(key)
            if not isinstance(value, str) or not value:
                continue
            for alias in (value, value.rsplit("/", 1)[-1]):
                if alias and alias not in aliases:
                    aliases.append(alias)
        return aliases

    def _select_metadata_template(
        self,
        model: dict[str, Any],
        templates: list[dict[str, Any]],
    ) -> tuple[dict[str, Any] | None, bool]:
        if not templates:
            return None, False

        by_alias: dict[str, dict[str, Any]] = {}
        for template in templates:
            for alias in self._model_aliases(template):
                by_alias.setdefault(alias, template)

        source_aliases = self._model_aliases(model)
        for alias in source_aliases:
            template = by_alias.get(alias)
            if template is not None:
                return template, True

        def family_match(aliases: list[str]) -> dict[str, Any] | None:
            best: tuple[int, dict[str, Any]] | None = None
            for alias in aliases:
                source_parts = alias.lower().split("-")
                for template in templates:
                    template_slug = _model_id(template)
                    if template_slug is None:
                        continue
                    template_parts = template_slug.lower().rsplit("/", 1)[-1].split("-")
                    score = 0
                    for source_part, template_part in zip(
                        source_parts,
                        template_parts,
                    ):
                        if source_part != template_part:
                            break
                        score += 1
                    if score < 2:
                        continue
                    if best is None or score > best[0]:
                        best = (score, template)
            return best[1] if best is not None else None

        template = family_match(source_aliases)
        if template is not None:
            return template, False

        desired_aliases = [
            self.desired_model,
            self.desired_model.rsplit("/", 1)[-1],
        ]
        for alias in desired_aliases:
            template = by_alias.get(alias)
            if template is not None:
                return template, False

        template = family_match(desired_aliases)
        if template is not None:
            return template, False

        for template in templates:
            if (
                template.get("visibility") == "list"
                and template.get("supported_in_api") is not False
            ):
                return template, False
        return templates[0], False

    @staticmethod
    def _replace_template_identity(
        model: dict[str, Any],
        template_slug: str,
        replacement: str,
    ) -> None:
        if not template_slug or not replacement or template_slug == replacement:
            return

        base_instructions = model.get("base_instructions")
        if isinstance(base_instructions, str):
            model["base_instructions"] = base_instructions.replace(
                template_slug,
                replacement,
            )

        model_messages = model.get("model_messages")
        if not isinstance(model_messages, dict):
            return
        instructions_template = model_messages.get("instructions_template")
        if isinstance(instructions_template, str):
            model_messages["instructions_template"] = instructions_template.replace(
                template_slug,
                replacement,
            )

    def _enrich_model_metadata(
        self,
        models: list[dict[str, Any]],
        templates: list[dict[str, Any]],
        *,
        log_result: bool = True,
    ) -> list[dict[str, Any]]:
        enriched: list[dict[str, Any]] = []
        exact_matches = 0
        template_fallbacks = 0
        static_fallbacks = 0

        for model in models:
            slug = _model_id(model)
            if slug is None:
                continue
            display_name = _model_display_name(model, slug)
            template, exact_match = self._select_metadata_template(model, templates)

            if template is None:
                merged = _default_native_model(slug, display_name)
                static_fallbacks += 1
            else:
                merged = deepcopy(template)
                if exact_match:
                    exact_matches += 1
                else:
                    template_fallbacks += 1

            source_fields = _model_source_fields(model)
            for key in source_fields:
                if key in MODEL_INTERNAL_KEYS or key not in model:
                    continue
                merged[key] = deepcopy(model[key])

            defaults = _default_native_model(slug, display_name)
            for key, value in defaults.items():
                merged.setdefault(key, deepcopy(value))
            _synchronize_reasoning_summary_fields(merged)
            if exact_match or "input_modalities" in source_fields:
                merged["input_modalities"] = _input_modalities_or_default(merged)
            else:
                # A fallback template is not evidence that the remote model
                # accepts images. Keep unknown models text-only by default.
                merged["input_modalities"] = list(DEFAULT_INPUT_MODALITIES)

            merged["slug"] = slug
            merged["id"] = slug
            if (
                exact_match
                and template is not None
                and "display_name" not in source_fields
            ):
                merged["display_name"] = _model_display_name(template, display_name)
            else:
                merged["display_name"] = display_name

            provider = model.get("provider") or model.get("owned_by")
            if isinstance(provider, str) and provider:
                merged["provider"] = provider

            # API discovery decides which additional identities are displayed.
            # Provider metadata and source-supplied visibility flags must not
            # veto a model returned by the configured /models endpoint.
            merged["visibility"] = "list"
            merged["supported_in_api"] = True

            if not exact_match and template is not None:
                replacement = model.get("name")
                if not isinstance(replacement, str) or not replacement:
                    replacement = slug.rsplit("/", 1)[-1]
                template_slug = _model_id(template) or ""
                self._replace_template_identity(
                    merged,
                    template_slug.rsplit("/", 1)[-1],
                    replacement,
                )
                if "description" not in source_fields:
                    if isinstance(provider, str) and provider:
                        merged["description"] = f"{display_name} via {provider}."
                    else:
                        merged["description"] = None

            merged["_source_fields"] = tuple(sorted(source_fields))
            enriched.append(merged)

        if log_result and models:
            _log(
                "info",
                "[codex-patch] Model metadata enriched at startup: "
                f"rows={len(enriched)}, exact_catalog={exact_matches}, "
                f"catalog_fallback={template_fallbacks}, "
                f"static_fallback={static_fallbacks}",
            )
        return enriched

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
            mode = self._infer_model_array_mode(body, request)
            changed = self._patch_model_array(body, mode=mode)

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

    @staticmethod
    def _infer_model_array_mode(rows: list[Any], request) -> str:
        native_score = 0
        openai_score = 0

        for row in rows:
            if _looks_like_native_model(row):
                native_score += 3
                continue
            if _looks_like_openai_model(row):
                openai_score += 3
                continue
            if not isinstance(row, dict):
                continue
            if isinstance(row.get("slug"), str):
                native_score += 1
            elif isinstance(row.get("id"), str):
                openai_score += 1

        if native_score != openai_score:
            return "native" if native_score > openai_score else "openai"

        path = _request_path(request).rstrip("/").lower()
        if path.endswith("/v1/models"):
            return "openai"
        return "native"

    @staticmethod
    def _native_response_template(
        rows: list[Any], desired_model: str
    ) -> dict[str, Any] | None:
        native_rows = [row for row in rows if _looks_like_native_model(row)]
        if not native_rows:
            return None

        desired_aliases = {
            desired_model,
            desired_model.rsplit("/", 1)[-1],
        }
        for row in native_rows:
            slug = _model_id(row)
            if slug in desired_aliases or (
                isinstance(slug, str) and slug.rsplit("/", 1)[-1] in desired_aliases
            ):
                return row
        for row in native_rows:
            if row.get("visibility") == "list":
                return row
        return native_rows[0]

    def _catalog_model_for_row(self, row: dict[str, Any]) -> dict[str, Any] | None:
        slug = _model_id(row)
        if slug is None:
            return None
        catalog_model = self.catalog_by_slug.get(slug)
        if catalog_model is not None:
            return catalog_model

        normalized = self._normalize_model_rows([row])
        if not normalized:
            return None
        enriched = self._enrich_model_metadata(
            normalized,
            self.metadata_models,
            log_result=False,
        )
        return enriched[0] if enriched else None

    @staticmethod
    def _native_model_from_catalog(
        model: dict[str, Any],
        template: dict[str, Any] | None,
    ) -> dict[str, Any]:
        slug = _model_id(model)
        if slug is None:
            return {}
        display_name = _model_display_name(model, slug)

        if template is not None:
            row = deepcopy(template)
        else:
            row = _default_native_model(slug, display_name)

        for key, value in model.items():
            if key in MODEL_INTERNAL_KEYS or key in MODEL_SOURCE_ONLY_KEYS:
                continue
            row[key] = deepcopy(value)

        defaults = _default_native_model(slug, display_name)
        for key, value in defaults.items():
            row.setdefault(key, deepcopy(value))
        _synchronize_reasoning_summary_fields(row)
        row["input_modalities"] = _input_modalities_or_default(model)

        for key in MODEL_INTERNAL_KEYS | MODEL_SOURCE_ONLY_KEYS:
            row.pop(key, None)

        row["slug"] = slug
        row["display_name"] = display_name
        row["visibility"] = "list"
        row["supported_in_api"] = True
        return row

    def _patch_model_array(self, rows: list[Any], mode: str) -> bool:
        native_template = (
            self._native_response_template(rows, self.desired_model)
            if mode == "native"
            else None
        )

        changed = False
        existing: set[str] = set()
        complete_ids = {
            slug
            for row in rows
            if (
                (mode == "native" and _looks_like_native_model(row))
                or (mode == "openai" and _looks_like_openai_model(row))
            )
            for slug in [_model_id(row)]
            if slug is not None
        }
        patched_rows: list[Any] = []
        for row in rows:
            is_complete = (
                (mode == "native" and _looks_like_native_model(row))
                or (mode == "openai" and _looks_like_openai_model(row))
            )
            converted: dict[str, Any] | None = None
            if not is_complete:
                source_model = self._catalog_model_for_row(row)
                if source_model is not None:
                    if mode == "native":
                        converted = self._native_model_from_catalog(
                            source_model,
                            native_template,
                        )
                    else:
                        converted = _openai_model_from_catalog(source_model)

            final_row = converted or row
            slug = _model_id(final_row)
            if slug is None:
                patched_rows.append(final_row)
                continue
            if (not is_complete and slug in complete_ids) or slug in existing:
                changed = True
                continue
            if converted is not None:
                changed = True
            patched_rows.append(final_row)
            existing.add(slug)

        if len(patched_rows) != len(rows):
            changed = True
        rows[:] = patched_rows

        for model in self.catalog_models:
            slug = model["slug"]
            if slug in existing:
                continue
            if mode == "openai":
                row = _openai_model_from_catalog(model)
            else:
                row = self._native_model_from_catalog(model, native_template)
            if not row:
                continue
            rows.append(row)
            existing.add(slug)
            changed = True

        return changed

    def _patch_statsig_response(self, flow, response) -> None:
        if not flow.metadata.get(
            "codex_patch_statsig_initialize"
        ) and not _is_statsig_initialize(flow.request):
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

    def _patch_wham_statsig_response(self, request, response) -> None:
        status = getattr(response, "status_code", 0)
        if not isinstance(status, int) or not 200 <= status < 300:
            return

        body = self._read_json_response(response)
        if not isinstance(body, dict):
            _log(
                "warn",
                "[codex-patch] WHAM Statsig bootstrap not patched: "
                f"host={getattr(request, 'pretty_host', request.host)} "
                f"path={_request_path(request)} reason=not_json_object",
            )
            return

        raw_payload = body.get("statsigPayload")
        if not isinstance(raw_payload, str):
            _log(
                "warn",
                "[codex-patch] WHAM Statsig bootstrap not patched: "
                f"host={getattr(request, 'pretty_host', request.host)} "
                f"path={_request_path(request)} reason=missing_statsigPayload_string",
            )
            return

        try:
            payload = json.loads(raw_payload)
        except (ValueError, TypeError) as exc:
            _log(
                "warn",
                "[codex-patch] WHAM Statsig bootstrap not patched: "
                f"host={getattr(request, 'pretty_host', request.host)} "
                f"path={_request_path(request)} reason=invalid_statsigPayload "
                f"error={exc}",
            )
            return

        if not isinstance(payload, dict) or not isinstance(
            payload.get("dynamic_configs"), dict
        ):
            _log(
                "warn",
                "[codex-patch] WHAM Statsig bootstrap not patched: "
                f"host={getattr(request, 'pretty_host', request.host)} "
                f"path={_request_path(request)} reason=unknown_payload_shape",
            )
            return

        changed = self._patch_statsig_dynamic_configs(payload)
        if not changed:
            _log(
                "warn",
                "[codex-patch] WHAM Statsig bootstrap not patched: "
                f"host={getattr(request, 'pretty_host', request.host)} "
                f"path={_request_path(request)} reason=dynamic_config_patch_failed",
            )
            return

        self._patch_statsig_layer_configs(payload)
        payload["hash_used"] = "none"
        body["statsigPayload"] = json.dumps(
            payload,
            ensure_ascii=False,
            separators=(",", ":"),
        )
        response.set_text(json.dumps(body, ensure_ascii=False, separators=(",", ":")))
        _remove_stale_headers(response.headers)
        _log(
            "info",
            "[codex-patch] WHAM Statsig bootstrap patched: "
            f"host={getattr(request, 'pretty_host', request.host)} "
            f"path={_request_path(request)} {self._statsig_body_summary(payload)}",
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
                target_parts.append(
                    f"hidden:{_compact_value(target['use_hidden_models'])}"
                )
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
            _log(
                "error",
                f"[codex-patch] Failed to save Statsig snapshot to {path}: {exc}",
            )

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
                        json.dump(
                            template_body,
                            dst,
                            ensure_ascii=False,
                            separators=(",", ":"),
                        )
                    _log(
                        "info",
                        "[codex-patch] Statsig snapshot seeded from init-template.json",
                    )
                except (OSError, json.JSONDecodeError, ValueError) as exc:
                    _log(
                        "error",
                        f"[codex-patch] Failed to seed snapshot from template: {exc}",
                    )
                    return None
            else:
                _log(
                    "error",
                    f"[codex-patch] Statsig init-template not found: {template_path}",
                )
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
            _log(
                "error",
                f"[codex-patch] Failed to load Statsig snapshot {snapshot_path}: {exc}",
            )
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

    def _statsig_entry_summary(
        self, body: dict[str, Any], entry: Any
    ) -> dict[str, Any]:
        if not isinstance(entry, dict):
            return {"present": False}

        value = entry.get("value")
        shape = "value" if isinstance(value, dict) else None
        if not isinstance(value, dict):
            ref = entry.get("v")
            values = body.get("values")
            if (
                isinstance(values, list)
                and isinstance(ref, int)
                and 0 <= ref < len(values)
            ):
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
            if (
                isinstance(values, list)
                and isinstance(ref, int)
                and 0 <= ref < len(values)
            ):
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
            _log(
                "error", "[codex-patch] Statsig response has no dynamic_configs object"
            )
            return False

        changed = False
        for key in STATSIG_DYNAMIC_CONFIG_KEYS:
            entry = dynamic_configs.get(key)
            if not isinstance(entry, dict):
                dynamic_configs[key] = self._build_statsig_dynamic_config_entry(key)
                _log(
                    "info",
                    f"[codex-patch] Statsig dynamic config key {key} injected (missing in upstream)",
                )
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
            layer_configs[STATSIG_I18N_LAYER_CONFIG_KEY] = self._build_i18n_layer_entry(
                {}
            )
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

    def _patch_i18n_layer_entry(
        self, body: dict[str, Any], entry: dict[str, Any]
    ) -> bool:
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
    def _ensure_explicit_parameters(
        entry: dict[str, Any], names: tuple[str, ...]
    ) -> None:
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

        if self.desired_model in self.catalog_slugs and self.desired_model not in seen:
            result.append(self.desired_model)

        merged["available_models"] = result
        # Current desktop builds interpret true as "filter strictly through the
        # remote available_models allowlist". False keeps every app-server row
        # whose catalog metadata already marks it as visible.
        merged["use_hidden_models"] = False
        merged["default_model"] = self.desired_model
        return merged

    def _merged_i18n_layer_value(self, existing: dict[str, Any]) -> dict[str, Any]:
        merged = deepcopy(existing)
        merged["enable_i18n"] = self.enable_i18n
        merged["locale_source"] = self.locale_source
        return merged


addons = [CodexCatalogPatcher()]

from __future__ import annotations

from typing import Any

from fastapi import FastAPI, HTTPException, Request, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from sqlalchemy.exc import IntegrityError
from starlette.exceptions import HTTPException as StarletteHTTPException


# v0.7 §5.N — i18n templates for user-facing error messages.
#
# Keyed by ``(kind, key)`` → Chinese template with named ``{var}``
# placeholders. ``render_message`` looks up the template and formats it;
# call sites use the ``i18n_*`` helpers below (or build an AppError
# directly with ``message=render_message(kind, key, **vars)``).
#
# Scope: only errors that the author sees in the Toast / 最近错误 list.
# Internal-only failures (validation 422 from Pydantic, IntegrityError,
# generic 500) deliberately stay English/dev-facing — those are debug
# signal, not user copy. See plan §5.N.
#
# Envelope shape is unchanged: still ``{error: {kind, message, details}}``.
# Only the ``message`` string flips to Chinese, so the iOS/macOS
# ErrorMapping layer needs no changes.
_TEMPLATES: dict[tuple[str, str], str] = {
    # --- Chapter state machine (services/chapter_state.py) ---
    ("conflict", "chapter_status_invalid_action"): (
        "章节当前正在「{status_cn}」中，无法{action_cn}"
    ),
    # --- Chapter extract (v0.9.3 §5.DI) ---
    ("conflict", "no_draft_to_extract"): "本章没有正文可提取",
    # --- Chapter write jobs (v1.3.2 LL P1, 写作作业化) ---
    ("conflict", "chapter_write_in_progress"): "本章正在写作中，请等待当前生成完成或先停止生成",
    # --- Chapter / Book lookups ---
    ("not_found", "book"): "书籍不存在，可能已被删除",
    ("not_found", "chapter"): "章节不存在，可能已被删除",
    ("not_found", "character"): "角色不存在，可能已被删除",
    ("not_found", "timeline_event"): "时间线事件不存在，可能已被删除",
    ("not_found", "provider_key"): "未找到对应的 LLM Key，可能已被删除",
    # --- Agent persona (v1.0.0 EE §5.4) ---
    ("not_found", "agent_persona"): "未找到对应的 Agent 人格（role 不合法）",
    # --- Provider key / per-Agent binding ---
    ("conflict", "provider_key_agent_mismatch"): (
        "此 Key 已绑定到「{key_role_cn}」专用，无法用于「{requested_role_cn}」"
    ),
    # --- LLM upstream ---
    ("upstream", "llm_no_active_key"): "尚未配置可用的 LLM Key，请先到设置里添加并设为 active",
    ("upstream", "llm_generic"): "LLM 服务调用失败：{detail}",
    # --- Rate limit (v0.8 T-2, §5.T) ---
    ("rate_limited", "request_too_frequent"): "请求过于频繁，请稍候再试",
    # --- Extractor output validation (services/extractor_apply.py) ---
    ("upstream", "extractor_missing_summary"): "Extractor 输出缺少 summary 字段",
    ("upstream", "extractor_bad_timeline_events"): "Extractor 输出的 timeline_events 不是数组",
    ("upstream", "extractor_bad_character_updates"): "Extractor 输出的 character_updates 不是数组",
    ("upstream", "extractor_character_update_not_object"): "Extractor 角色更新条目不是对象",
    ("upstream", "extractor_character_patch_not_object"): "Extractor 角色更新的 patch 字段不是对象",
    ("upstream", "extractor_unknown_character"): "Extractor 引用了不存在的角色",
    ("upstream", "extractor_event_not_object"): "Extractor 时间线事件条目不是对象",
    ("upstream", "extractor_bad_event_type"): "Extractor 时间线事件类型不合法",
    ("upstream", "extractor_empty_event_text"): "Extractor 时间线事件文本为空",
}

# §5.N — chapter status English code → Chinese display.
CHAPTER_STATUS_CN: dict[str, str] = {
    "draft": "草稿",
    "prompt_ready": "提纲已就绪",
    "writing": "写作",
    "draft_ready": "初稿已就绪",
    "finalized": "已定稿",
}

# §5.N — chapter action English code → Chinese verb phrase.
CHAPTER_ACTION_CN: dict[str, str] = {
    "expand": "展开提纲",
    "write": "开始写作",
    "finalize": "定稿",
    "import": "导入正文",
    "reopen": "重新打开",
    "extract": "提取角色/时间线",
    # v1.4.0 (MM) P2 — standalone revision endpoint.
    "revise": "修订",
}

# §5.N — Agent role English code → Chinese label. Mirrors the
# AgentRole.displayName mapping in the iOS app.
AGENT_ROLE_CN: dict[str, str] = {
    "writer": "Writer 写手",
    "extractor": "Extractor 信息提取",
    "expander": "Expander 提纲展开",
}


def render_message(kind: str, key: str, **vars: Any) -> str:
    """Format a Chinese error message from the template registry.

    If the (kind, key) pair is missing, falls back to ``key`` itself so a
    typo at the call site degrades to a recognisable English token rather
    than a KeyError 500. Missing placeholder values likewise degrade to
    ``{name}`` in the output (we don't raise).
    """
    template = _TEMPLATES.get((kind, key))
    if template is None:
        return key
    try:
        return template.format(**vars)
    except KeyError:
        # A placeholder is missing — return the raw template so the dev
        # spots the bug without crashing the request.
        return template


class AppError(Exception):
    def __init__(
        self,
        kind: str,
        message: str,
        *,
        status_code: int,
        retryable: bool = False,
        details: dict[str, Any] | None = None,
    ) -> None:
        self.kind = kind
        self.message = message
        self.status_code = status_code
        self.retryable = retryable
        self.details = details or {}
        super().__init__(message)


def error_payload(error: AppError) -> dict[str, Any]:
    return {
        "error": {
            "kind": error.kind,
            "message": error.message,
            "retryable": error.retryable,
            "details": error.details,
        }
    }


def error_response(error: AppError) -> JSONResponse:
    return JSONResponse(status_code=error.status_code, content=error_payload(error))


def not_found(message: str = "Resource not found") -> AppError:
    return AppError("not_found", message, status_code=status.HTTP_404_NOT_FOUND)


def conflict(message: str, details: dict[str, Any] | None = None) -> AppError:
    return AppError("conflict", message, status_code=status.HTTP_409_CONFLICT, details=details)


def unauthorized(message: str = "Unauthorized") -> AppError:
    return AppError("unauthorized", message, status_code=status.HTTP_401_UNAUTHORIZED)


def upstream(message: str, *, retryable: bool = True, details: dict[str, Any] | None = None) -> AppError:
    return AppError(
        "upstream",
        message,
        status_code=status.HTTP_502_BAD_GATEWAY,
        retryable=retryable,
        details=details,
    )


# --- v0.7 §5.N i18n helper factories ----------------------------------------

def i18n_conflict(key: str, *, details: dict[str, Any] | None = None, **vars: Any) -> AppError:
    return conflict(render_message("conflict", key, **vars), details=details)


def i18n_not_found(key: str, *, details: dict[str, Any] | None = None, **vars: Any) -> AppError:
    err = AppError(
        "not_found",
        render_message("not_found", key, **vars),
        status_code=status.HTTP_404_NOT_FOUND,
        details=details,
    )
    return err


def i18n_upstream(
    key: str,
    *,
    retryable: bool = True,
    details: dict[str, Any] | None = None,
    **vars: Any,
) -> AppError:
    return upstream(
        render_message("upstream", key, **vars),
        retryable=retryable,
        details=details,
    )


def i18n_rate_limited(retry_after_seconds: int) -> AppError:
    """v0.8 T-2 (§5.T): 429 envelope used by the rate-limit middleware.

    ``details.code = "rate_limited"`` and ``details.retry_after_seconds``
    let the iOS / macOS ErrorMapping layer render a Toast + countdown
    without parsing the Chinese message. The HTTP-level ``Retry-After``
    header is set separately on the response by the middleware.
    """
    return AppError(
        "rate_limited",
        render_message("rate_limited", "request_too_frequent"),
        status_code=status.HTTP_429_TOO_MANY_REQUESTS,
        retryable=True,
        details={
            "code": "rate_limited",
            "retry_after_seconds": int(retry_after_seconds),
        },
    )


def install_exception_handlers(app: FastAPI) -> None:
    @app.exception_handler(AppError)
    async def handle_app_error(request: Request, exc: AppError) -> JSONResponse:
        return error_response(exc)

    @app.exception_handler(RequestValidationError)
    async def handle_validation_error(request: Request, exc: RequestValidationError) -> JSONResponse:
        return error_response(
            AppError(
                "validation",
                "Request validation failed",
                status_code=422,
                details={"errors": _json_safe(exc.errors())},
            )
        )

    @app.exception_handler(StarletteHTTPException)
    async def handle_http_exception(request: Request, exc: StarletteHTTPException) -> JSONResponse:
        if exc.status_code == status.HTTP_404_NOT_FOUND:
            kind = "not_found"
        elif exc.status_code == status.HTTP_401_UNAUTHORIZED:
            kind = "unauthorized"
        elif exc.status_code == status.HTTP_409_CONFLICT:
            kind = "conflict"
        elif exc.status_code < 500:
            kind = "validation"
        else:
            kind = "internal"
        message = str(exc.detail) if exc.detail else exc.__class__.__name__
        return error_response(
            AppError(
                kind,
                message,
                status_code=exc.status_code,
            )
        )

    @app.exception_handler(IntegrityError)
    async def handle_integrity_error(request: Request, exc: IntegrityError) -> JSONResponse:
        return error_response(
            AppError(
                "conflict",
                "Database constraint conflict",
                status_code=status.HTTP_409_CONFLICT,
                details={"error": str(exc.orig)},
            )
        )

    @app.exception_handler(Exception)
    async def handle_unexpected_error(request: Request, exc: Exception) -> JSONResponse:
        return error_response(
            AppError(
                "internal",
                "Internal server error",
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            )
        )


def _json_safe(value: Any) -> Any:
    if isinstance(value, dict):
        return {key: _json_safe(item) for key, item in value.items()}
    if isinstance(value, list):
        return [_json_safe(item) for item in value]
    if isinstance(value, tuple):
        return [_json_safe(item) for item in value]
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    return str(value)

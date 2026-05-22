from __future__ import annotations

from typing import Any

from fastapi import FastAPI, HTTPException, Request, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from sqlalchemy.exc import IntegrityError
from starlette.exceptions import HTTPException as StarletteHTTPException


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

from __future__ import annotations


class LLMError(Exception):
    def __init__(self, message: str, *, retryable: bool = True) -> None:
        self.retryable = retryable
        super().__init__(message)

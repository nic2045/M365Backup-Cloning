"""Read-only web API of one toolkit instance (ADR 0002, ADR 0008, ADR 0009, issue #55)."""

from .app import create_app

__all__ = ["create_app"]

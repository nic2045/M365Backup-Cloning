"""Starts the read-only API: python -m m365api (from web/api). Binds to 127.0.0.1 unless told otherwise."""

from __future__ import annotations

import os

import uvicorn

from .app import create_app


def main() -> None:
    host = os.environ.get("M365CLONING_API_HOST", "127.0.0.1")
    port = int(os.environ.get("M365CLONING_API_PORT", "8000"))
    uvicorn.run(create_app(), host=host, port=port, log_level="info")


if __name__ == "__main__":
    main()

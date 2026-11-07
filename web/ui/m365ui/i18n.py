"""Interface texts.

Every visible text goes through ``_()``. English is the source language; a
catalogue for another language can be added to ``CATALOGUES`` later without
touching the templates.
"""

from __future__ import annotations

DEFAULT_LANGUAGE = "en"

# language -> {English source text: translation}
CATALOGUES: dict[str, dict[str, str]] = {"en": {}}


def gettext(text: str, language: str = DEFAULT_LANGUAGE) -> str:
    return CATALOGUES.get(language, {}).get(text, text)


def _(text: str) -> str:
    return gettext(text)

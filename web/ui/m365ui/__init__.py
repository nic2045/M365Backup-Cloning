"""Read-only web interface of the toolkit (ADR 0002).

The interface talks to the server only through the routes in web/openapi.json
(``/api/...``). It knows no file paths of the core and rebuilds none of its rules.
"""

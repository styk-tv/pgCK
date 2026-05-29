#!/usr/bin/env python3
"""Regenerate web/static/protocol.json (CKD-3).

The protocol document is a committed STATIC asset served by the /assets
StaticFiles mount — there is no FastAPI handler computing it at runtime.
web/protocol.py::protocol_document() remains the single source of truth;
this script renders it to disk with default (hostname-independent) config.
The browser's live config still arrives via window.PGCK_DISPLAY_CONFIG, so
the static doc's subject/url fields are illustrative defaults only.

Usage:  python scripts/gen_protocol_json.py
"""
from __future__ import annotations

import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from web.protocol import protocol_document  # noqa: E402

OUT = pathlib.Path(__file__).resolve().parent.parent / "web" / "static" / "protocol.json"


def main() -> None:
    doc = protocol_document(None)  # None -> default config, no request hostname
    OUT.write_text(json.dumps(doc, indent=2) + "\n")
    print(f"wrote {OUT.relative_to(OUT.parent.parent.parent)}")


if __name__ == "__main__":
    main()

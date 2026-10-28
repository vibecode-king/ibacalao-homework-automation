#!/usr/bin/env python3
"""Parser-only Scrapling sidecar for iBacalao DEV/R&D.

This file deliberately imports only ``scrapling.Selector``. It does not import
fetchers, spiders, browser automation, stealth, proxy, or challenge-solving code.
The caller supplies HTML that the student's browser already loaded.
"""

from __future__ import annotations

import json
import logging
import resource
import sys
from typing import Any

from scrapling import Selector

MAX_INPUT_BYTES = 2 * 1024 * 1024
MAX_HTML_BYTES = 1536 * 1024
MAX_OUTPUT_BYTES = 1024 * 1024
MEMORY_LIMIT_BYTES = 512 * 1024 * 1024


def fail(reason: str) -> dict[str, Any]:
    return {"ok": False, "reason": reason}


def bounded_stdin() -> bytes:
    data = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
    if len(data) > MAX_INPUT_BYTES:
        raise ValueError("input_too_large")
    return data


def set_memory_ceiling() -> None:
    try:
        resource.setrlimit(resource.RLIMIT_AS, (MEMORY_LIMIT_BYTES, MEMORY_LIMIT_BYTES))
    except (ValueError, OSError):
        # macOS may decline RLIMIT_AS for some Python builds. The parent process
        # still enforces a 3-second wall clock and hard-kills malformed helpers.
        pass


def top_adaptive_match(page: Selector, signature: dict[str, Any]) -> tuple[list[Any], int]:
    """Estimate Scrapling's top score using its public integer threshold API."""
    low = 0
    high = 100
    best_threshold = -1
    best_matches: list[Any] = []
    while low <= high:
        threshold = (low + high) // 2
        matches = list(page.relocate(signature, percentage=threshold, selector_type=True))
        if matches:
            best_threshold = threshold
            best_matches = matches
            low = threshold + 1
        else:
            high = threshold - 1
    return best_matches, best_threshold


def repair(request: dict[str, Any]) -> dict[str, Any]:
    old_recipe = request.get("oldRecipe")
    signature = request.get("oldSignature")
    html = request.get("currentHtml")
    current_url = request.get("currentUrl")
    expected_entity = request.get("expectedEntity")

    if not isinstance(old_recipe, dict) or not isinstance(signature, dict) or not signature:
        return fail("insufficient_evidence")
    if old_recipe.get("entity") != expected_entity:
        return fail("insufficient_evidence")
    if not isinstance(html, str) or not isinstance(current_url, str):
        return fail("parser_error")
    if len(html.encode("utf-8")) > MAX_HTML_BYTES:
        return fail("parser_error")
    try:
        from urllib.parse import urlparse

        parsed_url = urlparse(current_url)
        if parsed_url.scheme not in {"http", "https"} or not parsed_url.hostname:
            return fail("parser_error")
    except Exception:
        return fail("parser_error")

    try:
        page = Selector(html, url=current_url)
        matches, score = top_adaptive_match(page, signature)
    except Exception:
        return fail("parser_error")

    if not matches or score < 0:
        return fail("no_candidate")
    if len(matches) != 1:
        return fail("ambiguous")

    candidate = matches[0]
    capture_id = None
    try:
        root = candidate._root
        parent = root.getparent()
        while parent is not None:
            if str(parent.tag).lower() == "ibacalao-card":
                capture_id = parent.attrib.get("data-capture-id")
                break
            parent = parent.getparent()
    except Exception:
        capture_id = None
    try:
        selector = str(candidate.generate_css_selector)
    except Exception:
        return fail("parser_error")
    if not selector:
        return fail("no_candidate")

    candidate_recipe = json.loads(json.dumps(old_recipe))
    source = candidate_recipe.setdefault("source", {})
    source["kind"] = "observed-dom"
    source["selector"] = selector

    return {
        "ok": True,
        "candidateRecipe": candidate_recipe,
        "confidence": score / 100.0,
        "evidence": {
            "candidateCount": 1,
            **({"captureId": capture_id} if capture_id else {}),
        },
    }


def signature(request: dict[str, Any]) -> dict[str, Any]:
    html = request.get("currentHtml")
    current_url = request.get("currentUrl")
    capture_id = request.get("captureId")
    if not isinstance(html, str) or not isinstance(current_url, str) or not isinstance(capture_id, str):
        return fail("parser_error")
    if not capture_id or len(capture_id) > 40 or not capture_id.replace("-", "").replace("_", "").isalnum():
        return fail("insufficient_evidence")
    if len(html.encode("utf-8")) > MAX_HTML_BYTES:
        return fail("parser_error")
    try:
        page = Selector(
            html,
            url=current_url,
            adaptive=True,
            storage_args={"storage_file": ":memory:"},
        )
        selector = f'ibacalao-card[data-capture-id="{capture_id}"] > *'
        matches = list(page.css(selector))
        if len(matches) != 1:
            return fail("insufficient_evidence")
        page.save(matches[0], "ibacalao-signature")
        stored = page.retrieve("ibacalao-signature")
        if not isinstance(stored, dict) or not stored:
            return fail("insufficient_evidence")
        parent_attribs = stored.get("parent_attribs")
        if isinstance(parent_attribs, dict):
            parent_attribs.pop("data-capture-id", None)
        return {"ok": True, "signature": stored}
    except Exception:
        return fail("parser_error")


def main() -> int:
    logging.disable(logging.CRITICAL)
    set_memory_ceiling()
    try:
        request = json.loads(bounded_stdin())
        if not isinstance(request, dict):
            response = fail("parser_error")
        else:
            operation = request.get("operation", "repair")
            if operation == "signature":
                response = signature(request)
            elif operation == "repair":
                response = repair(request)
            else:
                response = fail("parser_error")
    except Exception:
        response = fail("parser_error")

    encoded = json.dumps(response, separators=(",", ":")).encode("utf-8")
    if len(encoded) > MAX_OUTPUT_BYTES:
        encoded = json.dumps(fail("parser_error"), separators=(",", ":")).encode("utf-8")
    sys.stdout.buffer.write(encoded + b"\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

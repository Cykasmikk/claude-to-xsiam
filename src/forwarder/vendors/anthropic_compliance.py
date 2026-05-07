"""Anthropic Compliance API — Activity Feed adapter.

Conforms to the Compliance API spec **Rev J, 2026-04-20** (PDF, distributed
by Anthropic to Enterprise customers with the Compliance API enabled).

Endpoint: GET https://api.anthropic.com/v1/compliance/activities
Auth:     x-api-key with sk-ant-admin01-... (Admin key) or
                          sk-ant-api01-... (Compliance Access Key)
Time:     created_at.gte / .lte (RFC 3339 strings, dotted notation)
Cursor:   after_id / before_id (response carries first_id, last_id, has_more)
Limit:    default 100, max 5000 per Rev J
"""

from __future__ import annotations

import json
import logging
import os
import time
from datetime import datetime, timezone
from typing import Iterator
from urllib.parse import urlencode

import urllib3

from . import AuditEvent

log = logging.getLogger(__name__)

VENDOR = "anthropic"

ANTHROPIC_API_BASE = "https://api.anthropic.com"
# Not strictly required by Rev J for the Compliance API but the wider
# Anthropic Admin API surface requires it; include defensively.
ANTHROPIC_VERSION = "2023-06-01"

COMPLIANCE_API_PATH = os.environ.get(
    "ANTHROPIC_COMPLIANCE_API_PATH", "/v1/compliance/activities"
)

PARAM_LIMIT = "limit"
PARAM_AFTER_ID = "after_id"
PARAM_CREATED_AT_GTE = "created_at.gte"
PARAM_CREATED_AT_LTE = "created_at.lte"
RESP_DATA = "data"
RESP_HAS_MORE = "has_more"
RESP_LAST_ID = "last_id"

PAGE_LIMIT = 1000

_VALID_KEY_PREFIXES = ("sk-ant-admin01-", "sk-ant-api01-")


class AnthropicComplianceAPIError(RuntimeError):
    """Raised on non-retriable Anthropic Compliance API responses."""


class AnthropicComplianceClient:
    vendor = VENDOR

    def __init__(
        self,
        api_key: str,
        api_base: str = ANTHROPIC_API_BASE,
        api_path: str = COMPLIANCE_API_PATH,
        http: urllib3.PoolManager | None = None,
    ):
        if not api_key.startswith(_VALID_KEY_PREFIXES):
            raise ValueError(
                "Anthropic Compliance API requires either an Admin key "
                "(sk-ant-admin01-...) provisioned via Console → Settings → "
                "Admin keys, OR a Compliance Access Key (sk-ant-api01-...) "
                "issued via Claude.ai → Org settings → Data and Privacy → "
                "Compliance access keys. Got a key with neither prefix."
            )
        self._key = api_key
        self._base = api_base.rstrip("/")
        self._path = api_path
        self._http = http or urllib3.PoolManager(retries=False, timeout=30.0)

    def _headers(self) -> dict:
        return {
            "x-api-key": self._key,
            "anthropic-version": ANTHROPIC_VERSION,
            "content-type": "application/json",
            "user-agent": "genai-audit-xsiam-forwarder/2.0",
        }

    def fetch_window(
        self,
        starting_at: datetime,
        ending_at: datetime,
    ) -> Iterator[AuditEvent]:
        base_params = {
            PARAM_LIMIT: PAGE_LIMIT,
            PARAM_CREATED_AT_GTE: _iso_z(starting_at),
            PARAM_CREATED_AT_LTE: _iso_z(ending_at),
        }
        after_id: str | None = None
        accumulated: list[AuditEvent] = []
        page_count = 0

        while True:
            params = dict(base_params)
            if after_id:
                params[PARAM_AFTER_ID] = after_id
            url = f"{self._base}{self._path}?{urlencode(params)}"

            payload = self._request_with_retry(url)
            data = payload.get(RESP_DATA, [])
            for raw in data:
                accumulated.append(
                    AuditEvent(
                        id=raw["id"],
                        created_at=raw["created_at"],
                        vendor=VENDOR,
                        raw=raw,
                    )
                )

            page_count += 1
            if not payload.get(RESP_HAS_MORE):
                break
            next_cursor = payload.get(RESP_LAST_ID)
            if not next_cursor or next_cursor == after_id:
                log.warning(
                    "Anthropic Compliance API has_more=true but last_id missing/unchanged"
                )
                break
            after_id = next_cursor

        log.info(
            "anthropic: fetched [%s, %s] pages=%d events=%d",
            base_params[PARAM_CREATED_AT_GTE],
            base_params[PARAM_CREATED_AT_LTE],
            page_count,
            len(accumulated),
        )

        accumulated.sort(key=lambda e: (e.created_at, e.id))
        for ev in accumulated:
            yield ev

    def _request_with_retry(self, url: str, attempts: int = 4) -> dict:
        backoff = 1.0
        for i in range(attempts):
            r = self._http.request("GET", url, headers=self._headers())
            if r.status == 404:
                raise AnthropicComplianceAPIError(
                    f"Anthropic Compliance API path not found: {self._path}. "
                    "Per Rev J 2026-04-20 the path is /v1/compliance/activities. "
                    "If a newer revision moved it, override via the "
                    f"ANTHROPIC_COMPLIANCE_API_PATH env var. Server response: {r.data[:200]!r}"
                )
            if r.status in (401, 403):
                raise AnthropicComplianceAPIError(
                    f"Anthropic Compliance API auth rejected (HTTP {r.status}). "
                    "Verify: (a) Compliance API is enabled (Org settings → "
                    "Data and Privacy → Compliance API), (b) the key has "
                    "read:compliance_activities scope, (c) the key has not "
                    f"been disabled or revoked. Response: {r.data[:200]!r}"
                )
            if r.status == 400:
                raise AnthropicComplianceAPIError(
                    f"Anthropic Compliance API rejected request (HTTP 400): {r.data[:500]!r}"
                )
            if r.status == 429 or 500 <= r.status < 600:
                if i == attempts - 1:
                    raise AnthropicComplianceAPIError(
                        f"Anthropic Compliance API failed after {attempts} attempts: "
                        f"HTTP {r.status} {r.data[:200]!r}"
                    )
                log.warning(
                    "Anthropic Compliance HTTP %s, retrying in %.1fs", r.status, backoff
                )
                time.sleep(backoff)
                backoff *= 2
                continue
            if r.status >= 400:
                raise AnthropicComplianceAPIError(
                    f"Anthropic Compliance API HTTP {r.status}: {r.data[:500]!r}"
                )
            return json.loads(r.data)
        raise AnthropicComplianceAPIError("unreachable")


def _iso_z(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")

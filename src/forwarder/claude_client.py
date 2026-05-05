"""Anthropic Claude Compliance API — Activity Feed client.

Conforms to the Compliance API spec **Rev J, 2026-04-20** (PDF, distributed by
Anthropic to Enterprise customers with the Compliance API enabled).

Key references:
  - Spec PDF:   "Compliance API: Activity Feed, Chats, Files, Organizations,
                Users, and Projects" — Rev J, 2026-04-20
  - Enable:     https://support.claude.com/en/articles/13015708-access-the-compliance-api
  - Overview:   https://claude.com/blog/claude-platform-compliance-api

This client only implements the **Activity Feed** endpoint, which is the
right scope for forwarding audit-relevant events to a SIEM. The other
Compliance API endpoints (chats, files, projects) cover content access /
e-discovery use cases and are out of scope here.

Activity Feed (Rev J):
    GET https://api.anthropic.com/v1/compliance/activities
    Headers:
        x-api-key: sk-ant-admin01-... (Admin key — Console/API customers)
                or sk-ant-api01-...   (Compliance Access Key — Claude.ai)
    Query params:
        created_at.gte / .gt / .lte / .lt   RFC 3339 inequalities
        organization_ids[]                  repeatable filter
        actor_ids[]                         repeatable filter
        activity_types[]                    repeatable filter
        after_id / before_id                cursor by activity_id
        limit                               default 100, max 5000
    Response:
        data: [Activity]                    newest-first within each page
        has_more: bool
        first_id: string                    pass as before_id for prev page
                                            (prev = forwards in time)
        last_id: string                     pass as after_id for next page
                                            (next = backwards in time)
    Activity object:
        id, created_at, organization_id, organization_uuid, actor, type,
        plus type-specific extra fields
    Activity ordering:
        Reverse chronological (newest first), ties broken by activity id.
"""

from __future__ import annotations

import json
import logging
import os
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Iterator
from urllib.parse import urlencode

import urllib3

log = logging.getLogger(__name__)

ANTHROPIC_API_BASE = "https://api.anthropic.com"
# Not strictly required by the Compliance API per Rev J (the PDF curl examples
# do not include it), but the wider Anthropic Admin API requires it and
# Compliance API runs on the same surface — include it defensively.
ANTHROPIC_VERSION = "2023-06-01"

# Confirmed against Rev J spec; overridable via env var so a future revision
# moving the path doesn't require a code change.
COMPLIANCE_API_PATH = os.environ.get(
    "COMPLIANCE_API_PATH", "/v1/compliance/activities"
)

# Activity Feed pagination (Rev J).
PARAM_LIMIT = "limit"
PARAM_AFTER_ID = "after_id"
PARAM_BEFORE_ID = "before_id"
PARAM_CREATED_AT_GTE = "created_at.gte"
PARAM_CREATED_AT_LTE = "created_at.lte"
RESP_DATA = "data"
RESP_HAS_MORE = "has_more"
RESP_FIRST_ID = "first_id"
RESP_LAST_ID = "last_id"

# Default page size. Rev J max is 5000; 1000 keeps responses small enough to
# parse without memory pressure and minimises per-page latency.
PAGE_LIMIT = 1000

# Admin keys grant `read:compliance_activities` (Activity Feed only).
# Compliance Access Keys can carry that scope plus user-data scopes.
_VALID_KEY_PREFIXES = ("sk-ant-admin01-", "sk-ant-api01-")


@dataclass
class ActivityEvent:
    """Compliance API Activity object (Rev J).

    `actor` holds a nested object whose `type` field discriminates the
    variant (UserActor / ApiActor / AdminApiKeyActor / UnauthenticatedUserActor
    / AnthropicActor / ScimDirectorySyncActor). We do not flatten it — the
    nested structure is what XSIAM ingests.
    """

    id: str
    created_at: str
    type: str
    actor: dict = field(default_factory=dict)
    organization_id: str | None = None
    organization_uuid: str | None = None
    raw: dict = field(default_factory=dict)

    @classmethod
    def from_payload(cls, payload: dict) -> "ActivityEvent":
        return cls(
            id=payload["id"],
            created_at=payload["created_at"],
            type=payload.get("type", "unknown"),
            actor=payload.get("actor") or {},
            organization_id=payload.get("organization_id"),
            organization_uuid=payload.get("organization_uuid"),
            raw=payload,
        )

    @property
    def created_at_dt(self) -> datetime:
        return datetime.fromisoformat(self.created_at.replace("Z", "+00:00"))


class ComplianceAPIError(RuntimeError):
    """Raised on non-retriable Compliance API responses."""


class ClaudeComplianceClient:
    def __init__(
        self,
        api_key: str,
        api_base: str = ANTHROPIC_API_BASE,
        api_path: str = COMPLIANCE_API_PATH,
        http: urllib3.PoolManager | None = None,
    ):
        if not api_key.startswith(_VALID_KEY_PREFIXES):
            raise ValueError(
                "Compliance API requires either an Admin key "
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
            "user-agent": "claude-xsiam-forwarder/1.0",
        }

    def fetch_window(
        self,
        starting_at: datetime,
        ending_at: datetime,
    ) -> Iterator[ActivityEvent]:
        """Yield activities whose `created_at` falls in [starting_at, ending_at].

        Pagination strategy (Rev J Activity Feed):
        - Filter by `created_at.gte` / `created_at.lte`.
        - The API returns newest-first within each page.
        - Page through OLDER events using `after_id={last_id}` until
          `has_more=false`.
        - Sort the accumulated events ascending by (created_at, id) and yield,
          so the caller's watermark advances monotonically and a mid-batch
          crash resumes correctly.
        """
        base_params = {
            PARAM_LIMIT: PAGE_LIMIT,
            PARAM_CREATED_AT_GTE: _iso_z(starting_at),
            PARAM_CREATED_AT_LTE: _iso_z(ending_at),
        }
        after_id: str | None = None
        accumulated: list[ActivityEvent] = []
        page_count = 0

        while True:
            params = dict(base_params)
            if after_id:
                params[PARAM_AFTER_ID] = after_id
            url = f"{self._base}{self._path}?{urlencode(params)}"

            payload = self._request_with_retry(url)
            data = payload.get(RESP_DATA, [])
            for raw in data:
                accumulated.append(ActivityEvent.from_payload(raw))

            page_count += 1

            if not payload.get(RESP_HAS_MORE):
                break
            next_cursor = payload.get(RESP_LAST_ID)
            if not next_cursor or next_cursor == after_id:
                # Defensive: API said has_more but didn't advance the cursor.
                log.warning("Compliance API has_more=true but last_id missing/unchanged")
                break
            after_id = next_cursor

        log.info(
            "fetched window [%s, %s] pages=%d events=%d",
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
                raise ComplianceAPIError(
                    f"Compliance API path not found: {self._path}. "
                    "Per Rev J the path is /v1/compliance/activities. If a "
                    "newer revision moved it, override via the "
                    f"COMPLIANCE_API_PATH env var. Server response: {r.data[:200]!r}"
                )
            if r.status in (401, 403):
                raise ComplianceAPIError(
                    f"Compliance API auth rejected (HTTP {r.status}). Verify: "
                    "(a) Compliance API is enabled for your organization "
                    "(Org settings → Data and Privacy → Compliance API), "
                    "(b) the key has the read:compliance_activities scope, "
                    "(c) the key has not been disabled or revoked. "
                    f"Response: {r.data[:200]!r}"
                )
            if r.status == 400:
                # Rev J 400 includes a structured `error.message` — surface it
                # to the operator unedited.
                raise ComplianceAPIError(
                    f"Compliance API rejected request (HTTP 400): {r.data[:500]!r}"
                )
            if r.status == 429 or 500 <= r.status < 600:
                if i == attempts - 1:
                    raise ComplianceAPIError(
                        f"Compliance API failed after {attempts} attempts: "
                        f"HTTP {r.status} {r.data[:200]!r}"
                    )
                log.warning(
                    "Compliance API HTTP %s, retrying in %.1fs", r.status, backoff
                )
                time.sleep(backoff)
                backoff *= 2
                continue
            if r.status >= 400:
                raise ComplianceAPIError(
                    f"Compliance API HTTP {r.status}: {r.data[:500]!r}"
                )
            return json.loads(r.data)
        raise ComplianceAPIError("unreachable")


def _iso_z(dt: datetime) -> str:
    """RFC 3339 with trailing Z, the format the Compliance API expects."""
    return dt.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")

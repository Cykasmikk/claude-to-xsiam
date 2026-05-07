"""OpenAI Audit Logs API adapter.

References (verified against authoritative sources):
  - Help center: https://help.openai.com/en/articles/9687866-admin-and-audit-logs-api-for-the-api-platform
  - API ref:     https://platform.openai.com/docs/api-reference/audit-logs
  - Methods ref: https://developers.openai.com/api/reference/resources/organization/subresources/audit_logs/methods/list

Endpoint: GET https://api.openai.com/v1/organization/audit_logs
Auth:     Authorization: Bearer <admin-key>  (prefix sk-admin-...)
Time:     effective_at[gte] / effective_at[lte]  (Unix seconds, bracketed)
Cursor:   after / before  (just IDs, no _id suffix unlike Anthropic)
Limit:    1-100, default 20

Field shape:
  - id: string
  - effective_at: int (Unix seconds — converted to ISO 8601 for the
    common AuditEvent shape)
  - type: dotted-namespace string (e.g. "api_key.created", "login.failed")
  - actor: discriminated by sub-key:
      session actor: actor.session.{ip_address, user.{id, email}}
      api_key actor: actor.api_key.{id, type, service_account, user}
  - project: {id, name} or null
  - <type-specific>: e.g. api_key.created carries {id, data:{scopes:[...]}}

Org Owner enables audit logging at:
  Organization settings → Data controls → Data retention → Audit logging
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

VENDOR = "openai"

OPENAI_API_BASE = "https://api.openai.com"

AUDIT_LOGS_PATH = os.environ.get(
    "OPENAI_AUDIT_LOGS_PATH", "/v1/organization/audit_logs"
)

PARAM_LIMIT = "limit"
PARAM_AFTER = "after"
# Bracket notation (urlencode produces effective_at%5Bgte%5D=... which OpenAI
# accepts; we keep raw brackets in the dict key so the form is obvious).
PARAM_EFFECTIVE_AT_GTE = "effective_at[gte]"
PARAM_EFFECTIVE_AT_LTE = "effective_at[lte]"
RESP_DATA = "data"
RESP_HAS_MORE = "has_more"
RESP_LAST_ID = "last_id"

# OpenAI caps page size at 100 (vs. Anthropic's 5000). At 5-min poll cadence
# even a busy org rarely emits >100 audit events per window, but be ready
# to paginate.
PAGE_LIMIT = 100

_VALID_KEY_PREFIX = "sk-admin-"


class OpenAIAuditAPIError(RuntimeError):
    """Raised on non-retriable OpenAI Audit Logs API responses."""


class OpenAIAuditClient:
    vendor = VENDOR

    def __init__(
        self,
        api_key: str,
        api_base: str = OPENAI_API_BASE,
        api_path: str = AUDIT_LOGS_PATH,
        http: urllib3.PoolManager | None = None,
    ):
        if not api_key.startswith(_VALID_KEY_PREFIX):
            raise ValueError(
                "OpenAI Audit Logs API requires an Admin key (sk-admin-...). "
                "Provision via Platform dashboard → Admin keys → Create new "
                "admin key. Only Organization Owners can create or use Admin "
                "keys; standard sk-... project keys cannot read audit logs."
            )
        self._key = api_key
        self._base = api_base.rstrip("/")
        self._path = api_path
        self._http = http or urllib3.PoolManager(retries=False, timeout=30.0)

    def _headers(self) -> dict:
        return {
            "Authorization": f"Bearer {self._key}",
            "Content-Type": "application/json",
            "User-Agent": "genai-audit-xsiam-forwarder/2.0",
        }

    def fetch_window(
        self,
        starting_at: datetime,
        ending_at: datetime,
    ) -> Iterator[AuditEvent]:
        base_params = {
            PARAM_LIMIT: PAGE_LIMIT,
            PARAM_EFFECTIVE_AT_GTE: _to_unix(starting_at),
            PARAM_EFFECTIVE_AT_LTE: _to_unix(ending_at),
        }
        after: str | None = None
        accumulated: list[AuditEvent] = []
        page_count = 0

        while True:
            params = dict(base_params)
            if after:
                params[PARAM_AFTER] = after
            url = f"{self._base}{self._path}?{urlencode(params)}"

            payload = self._request_with_retry(url)
            data = payload.get(RESP_DATA, [])
            for raw in data:
                accumulated.append(
                    AuditEvent(
                        id=raw["id"],
                        # Convert Unix seconds → ISO 8601 UTC for the common
                        # shape; preserve raw["effective_at"] in `raw` for
                        # XSIAM operators who want the original.
                        created_at=_unix_to_iso(raw["effective_at"]),
                        vendor=VENDOR,
                        raw=raw,
                    )
                )

            page_count += 1
            if not payload.get(RESP_HAS_MORE):
                break
            next_cursor = payload.get(RESP_LAST_ID)
            if not next_cursor or next_cursor == after:
                log.warning(
                    "OpenAI Audit Logs has_more=true but last_id missing/unchanged"
                )
                break
            after = next_cursor

        log.info(
            "openai: fetched [%d, %d] pages=%d events=%d",
            base_params[PARAM_EFFECTIVE_AT_GTE],
            base_params[PARAM_EFFECTIVE_AT_LTE],
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
                raise OpenAIAuditAPIError(
                    f"OpenAI Audit Logs path not found: {self._path}. "
                    "Documented path is /v1/organization/audit_logs. If a "
                    "newer revision moved it, override via the "
                    f"OPENAI_AUDIT_LOGS_PATH env var. Server response: {r.data[:200]!r}"
                )
            if r.status in (401, 403):
                raise OpenAIAuditAPIError(
                    f"OpenAI Audit Logs auth rejected (HTTP {r.status}). "
                    "Verify: (a) audit logging is enabled (Organization "
                    "settings → Data controls → Data retention → Audit "
                    "logging), (b) the key starts with sk-admin- and was "
                    "issued by an Organization Owner, (c) the Owner who "
                    "issued it has not had their role revoked. "
                    f"Response: {r.data[:200]!r}"
                )
            if r.status == 400:
                raise OpenAIAuditAPIError(
                    f"OpenAI Audit Logs rejected request (HTTP 400): {r.data[:500]!r}"
                )
            if r.status == 429 or 500 <= r.status < 600:
                if i == attempts - 1:
                    raise OpenAIAuditAPIError(
                        f"OpenAI Audit Logs failed after {attempts} attempts: "
                        f"HTTP {r.status} {r.data[:200]!r}"
                    )
                log.warning(
                    "OpenAI Audit Logs HTTP %s, retrying in %.1fs", r.status, backoff
                )
                time.sleep(backoff)
                backoff *= 2
                continue
            if r.status >= 400:
                raise OpenAIAuditAPIError(
                    f"OpenAI Audit Logs HTTP {r.status}: {r.data[:500]!r}"
                )
            return json.loads(r.data)
        raise OpenAIAuditAPIError("unreachable")


def _to_unix(dt: datetime) -> int:
    return int(dt.astimezone(timezone.utc).timestamp())


def _unix_to_iso(ts: int) -> str:
    return (
        datetime.fromtimestamp(int(ts), tz=timezone.utc)
        .isoformat()
        .replace("+00:00", "Z")
    )

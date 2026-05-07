"""Vendor-adapter pattern.

Each supported GenAI platform's audit-log API is wrapped in an `AuditClient`
that yields a stream of common-shape `AuditEvent` objects. The vendor-native
payload is preserved verbatim in `AuditEvent.raw` so XSIAM operators can
configure parsers against the original schema without translation gotchas.

Adapters live in this package:
  - `anthropic_compliance.py` — Anthropic Compliance API (Activity Feed)
  - `openai_audit.py`         — OpenAI Audit Logs API
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from typing import Iterator, Protocol


@dataclass
class AuditEvent:
    """Common-shape audit event used by core.run().

    Each vendor adapter populates these fields from its native schema:
      - `id`: stable per-event identifier (used for dedupe).
      - `created_at`: ISO 8601 / RFC 3339 string in UTC. Vendors that emit
        Unix timestamps must convert to ISO here.
      - `vendor`: lowercase vendor key (e.g. "anthropic", "openai").
      - `raw`: vendor-native payload, untouched.
    """

    id: str
    created_at: str
    vendor: str
    raw: dict = field(default_factory=dict)

    @property
    def created_at_dt(self) -> datetime:
        return datetime.fromisoformat(self.created_at.replace("Z", "+00:00"))


class AuditClient(Protocol):
    """Vendor adapter contract.

    `vendor` is a lowercase identifier baked into S3 keys, Pub/Sub
    attributes, state document keys, and XSIAM `_vendor` enrichment.
    """

    vendor: str

    def fetch_window(
        self, starting_at: datetime, ending_at: datetime
    ) -> Iterator[AuditEvent]: ...


__all__ = ["AuditEvent", "AuditClient"]

"""Forwarder state backend protocol.

State documents are namespaced by vendor so multiple vendors share one
DynamoDB table / Firestore collection without cross-contamination.

Persisted state per vendor:
  - `watermark`: ISO 8601 created_at of the latest event we've forwarded.
  - `recent_ids`: bounded set of activity IDs at-or-near the watermark for
    overlap-window dedupe.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Protocol


@dataclass
class ForwarderState:
    watermark: str | None = None
    recent_ids: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {"watermark": self.watermark, "recent_ids": self.recent_ids}

    @classmethod
    def from_dict(cls, d: dict | None) -> "ForwarderState":
        if not d:
            return cls()
        return cls(
            watermark=d.get("watermark"),
            # Tolerate the legacy field name from before Rev J was published.
            recent_ids=list(d.get("recent_ids") or d.get("recent_hashes") or []),
        )


class StateStore(Protocol):
    """Per-vendor state store. Implementations are constructed for one
    vendor and isolate that vendor's state from others."""

    vendor: str

    def load(self) -> ForwarderState: ...
    def save(self, state: ForwarderState) -> None: ...

"""Forwarder state backend protocol.

The Compliance API Activity Feed assigns every event a stable `id` of the
form `activity_xxx`, so dedupe keys directly off that — no content hashing
needed.

Persisted state:
  - `watermark`: ISO 8601 `created_at` of the latest event we've forwarded.
  - `recent_ids`: bounded set of activity IDs at-or-near the watermark.
    Used to dedupe the inevitable overlap when the next poll re-queries the
    boundary window to handle clock skew and out-of-order delivery.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Protocol


@dataclass
class ForwarderState:
    watermark: str | None = None  # ISO 8601 created_at of newest forwarded event
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
    def load(self) -> ForwarderState: ...
    def save(self, state: ForwarderState) -> None: ...

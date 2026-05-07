"""Cloud-agnostic + vendor-agnostic fetch → forward → checkpoint loop.

Idempotency model
-----------------
Every supported vendor's audit feed assigns a stable per-event `id`, so
dedupe is keyed on that ID directly. Each tick:

  1. Loads the prior state for this vendor: a watermark (latest `created_at`
     ever forwarded) and a bounded set of recent IDs.
  2. Queries the vendor's API for the window
        [watermark - OVERLAP_SECONDS, now]
     to absorb clock skew and out-of-order delivery near the boundary.
  3. Drops events whose `id` is already in `recent_ids`.
  4. Forwards the survivors to the configured egress sink.
  5. Persists the advanced watermark + refreshed ID set **only after** the
     egress sink ACKs — a crash mid-batch replays the same window cleanly
     on the next tick.

State documents are namespaced by vendor so multiple vendors share one
DynamoDB table / Firestore collection without cross-contamination.
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone

from .egress import Egress
from .state import ForwarderState, StateStore
from .vendors import AuditClient, AuditEvent

log = logging.getLogger(__name__)

OVERLAP_SECONDS = 300
MAX_RECENT_IDS = 10_000
PENDING_FLUSH_AT = 1000


def run(
    client: AuditClient,
    egress: Egress,
    store: StateStore,
    initial_lookback_minutes: int = 60,
    now: datetime | None = None,
) -> dict:
    """Pull new audit events for one vendor and forward to the egress sink."""
    now = now or datetime.now(timezone.utc)
    state = store.load()

    if state.watermark:
        starting_at = _parse_iso(state.watermark) - timedelta(seconds=OVERLAP_SECONDS)
        first_run = False
    else:
        starting_at = now - timedelta(minutes=initial_lookback_minutes)
        first_run = True

    log.info(
        "%s: starting run first_run=%s window=[%s, %s] prior_ids=%d",
        client.vendor,
        first_run,
        starting_at.isoformat(),
        now.isoformat(),
        len(state.recent_ids),
    )

    seen = set(state.recent_ids)
    pending: list[AuditEvent] = []
    forwarded = 0
    skipped_duplicate = 0
    new_watermark = state.watermark

    def flush() -> None:
        nonlocal forwarded
        if not pending:
            return
        egress.send(ev.raw for ev in pending)
        forwarded += len(pending)
        store.save(_compute_state(seen, new_watermark))
        pending.clear()

    for ev in client.fetch_window(starting_at, now):
        if ev.id in seen:
            skipped_duplicate += 1
            continue
        seen.add(ev.id)
        pending.append(ev)
        if new_watermark is None or ev.created_at > new_watermark:
            new_watermark = ev.created_at
        if len(pending) >= PENDING_FLUSH_AT:
            flush()

    flush()

    summary = {
        "vendor": client.vendor,
        "first_run": first_run,
        "forwarded": forwarded,
        "skipped_duplicate": skipped_duplicate,
        "watermark": new_watermark,
    }
    log.info("%s: run complete %s", client.vendor, summary)
    return summary


def _compute_state(seen: set[str], watermark: str | None) -> ForwarderState:
    if len(seen) > MAX_RECENT_IDS:
        trimmed = list(seen)[-MAX_RECENT_IDS:]
    else:
        trimmed = list(seen)
    return ForwarderState(watermark=watermark, recent_ids=trimmed)


def _parse_iso(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))

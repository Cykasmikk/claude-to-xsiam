"""Cloud-agnostic fetch → forward → checkpoint loop.

Idempotency model
-----------------
Compliance API Rev J assigns every Activity a stable `id` (`activity_xxx`),
so dedupe is keyed on that ID directly. Each tick:

  1. Loads the prior state: a watermark (latest `created_at` ever forwarded)
     and a bounded set of recent activity IDs.
  2. Queries the API for the window
        [watermark - OVERLAP_SECONDS, now]
     to absorb clock skew and out-of-order delivery near the boundary.
  3. Drops events whose `id` is already in `recent_ids`.
  4. Forwards the survivors to the configured egress sink.
  5. Persists the advanced watermark + refreshed ID set **only after** the
     egress sink ACKs the batch — a crash mid-batch replays the same window
     cleanly on the next tick.
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone

from .claude_client import ActivityEvent, ClaudeComplianceClient
from .egress import Egress
from .state import ForwarderState, StateStore

log = logging.getLogger(__name__)

# How far back of the watermark we re-query each tick. Rev J says the
# Activity Feed is queryable within ~1 minute of the actual event; 5 minutes
# of overlap is generous insurance against clock skew and out-of-order
# delivery without re-shipping more than necessary.
OVERLAP_SECONDS = 300

# Cap on `recent_ids`. With OVERLAP_SECONDS=300 and realistic Enterprise
# audit volumes (~hundreds/hour), 10 000 IDs is far more than the overlap
# window will ever contain, while keeping the persisted state document well
# under DynamoDB's 400 KB and Firestore's 1 MB item-size limits.
MAX_RECENT_IDS = 10_000

PENDING_FLUSH_AT = 1000


def run(
    claude: ClaudeComplianceClient,
    egress: Egress,
    store: StateStore,
    initial_lookback_minutes: int = 60,
    now: datetime | None = None,
) -> dict:
    """Pull new audit events and forward them to the configured egress sink."""
    now = now or datetime.now(timezone.utc)
    state = store.load()

    if state.watermark:
        starting_at = _parse_iso(state.watermark) - timedelta(seconds=OVERLAP_SECONDS)
        first_run = False
    else:
        starting_at = now - timedelta(minutes=initial_lookback_minutes)
        first_run = True

    log.info(
        "starting run first_run=%s window=[%s, %s] prior_ids=%d",
        first_run,
        starting_at.isoformat(),
        now.isoformat(),
        len(state.recent_ids),
    )

    seen = set(state.recent_ids)
    pending: list[ActivityEvent] = []
    forwarded = 0
    skipped_duplicate = 0
    new_watermark = state.watermark

    def flush() -> None:
        nonlocal forwarded
        if not pending:
            return
        egress.send(ev.raw for ev in pending)
        forwarded += len(pending)
        # Persist only after the egress sink ACKs so a later failure can't
        # undo work that has already been accepted downstream.
        store.save(_compute_state(seen, new_watermark))
        pending.clear()

    for ev in claude.fetch_window(starting_at, now):
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
        "first_run": first_run,
        "forwarded": forwarded,
        "skipped_duplicate": skipped_duplicate,
        "watermark": new_watermark,
    }
    log.info("run complete %s", summary)
    return summary


def _compute_state(seen: set[str], watermark: str | None) -> ForwarderState:
    if len(seen) > MAX_RECENT_IDS:
        # Order is irrelevant — only membership matters — so trim arbitrarily.
        trimmed = list(seen)[-MAX_RECENT_IDS:]
    else:
        trimmed = list(seen)
    return ForwarderState(watermark=watermark, recent_ids=trimmed)


def _parse_iso(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))

"""Pub/Sub egress: publishes audit events to a Pub/Sub topic.

XSIAM's "GCP Pub/Sub" data source pulls from a customer-owned subscription
using a service account credentials file. We publish; XSIAM consumes.

Each audit event becomes one Pub/Sub message:
- `data` is the raw Compliance API event JSON (UTF-8 bytes)
- `attributes` carry small routing/filter hints (event type, actor user_id,
  client_platform) for any XSIAM-side filtering needs without parsing the body

We block on each publish future to surface failures synchronously, so the
forwarder can refuse to advance the watermark past unsent events.
"""

from __future__ import annotations

import json
import logging
from typing import Iterable

log = logging.getLogger(__name__)


class PubSubEgress:
    def __init__(self, project: str, topic: str, publisher=None):
        self._project = project
        self._topic = topic
        if publisher is not None:
            self._publisher = publisher
        else:
            from google.cloud import pubsub_v1  # deferred for dev import
            self._publisher = pubsub_v1.PublisherClient(
                publisher_options=pubsub_v1.types.PublisherOptions(
                    enable_message_ordering=False,
                )
            )
        self._topic_path = self._publisher.topic_path(project, topic)

    def send(self, events: Iterable[dict]) -> int:
        materialized = list(events)
        if not materialized:
            return 0

        futures = []
        for ev in materialized:
            data = json.dumps(ev, separators=(",", ":")).encode("utf-8")
            attrs = self._attributes(ev)
            futures.append(self._publisher.publish(self._topic_path, data, **attrs))

        # Block on every future. If any raises, the exception propagates and
        # core.run() will not advance the watermark past this batch.
        for fut in futures:
            fut.result(timeout=30)

        log.info(
            "published %d events to projects/%s/topics/%s",
            len(materialized),
            self._project,
            self._topic,
        )
        return len(materialized)

    def _attributes(self, ev: dict) -> dict:
        # Pub/Sub attribute values have a 1024-byte cap; keep them tiny.
        # Schema follows Compliance API Rev J Activity object: top-level
        # `type` and `organization_id`, nested `actor.user_id` / `actor.type`.
        attrs = {}
        if isinstance(ev.get("type"), str):
            attrs["activity_type"] = ev["type"][:256]
        if isinstance(ev.get("organization_id"), str):
            attrs["organization_id"] = ev["organization_id"][:64]
        actor = ev.get("actor") or {}
        if isinstance(actor.get("type"), str):
            attrs["actor_type"] = actor["type"][:64]
        if isinstance(actor.get("user_id"), str):
            attrs["actor_user_id"] = actor["user_id"][:256]
        elif isinstance(actor.get("api_key_id"), str):
            attrs["actor_api_key_id"] = actor["api_key_id"][:256]
        return attrs

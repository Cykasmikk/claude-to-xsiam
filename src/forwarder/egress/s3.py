"""S3 egress: writes audit events as gzipped JSON-lines to S3.

XSIAM's "Amazon S3 generic logs" data source pulls objects from S3 driven
by SQS ObjectCreated notifications. Reference Palo-published architecture:
https://github.com/PaloAltoNetworks/terraform-umbrella-s3-to-xsiam-ingestion-module

Object layout
-------------
    s3://{bucket}/{vendor}/{prefix}/{yyyy}/{mm}/{dd}/{hh}/{run_id}.jsonl.gz

The leading `{vendor}/` segment lets XSIAM operators configure separate
data sources (and therefore separate datasets) per vendor: one source
listening for ObjectCreated notifications matching `anthropic/*`, another
for `openai/*`. SQS notification filters can be configured to deliver
events for one prefix only.

Format
------
- Newline-delimited JSON, one event per line (the raw vendor payload).
- gzip compressed (`Content-Encoding: gzip`,
  `Content-Type: application/x-ndjson`).
- Server-side encrypted (AES256 — defensive in case the bucket policy lapses).
"""

from __future__ import annotations

import gzip
import io
import json
import logging
import uuid
from datetime import datetime, timezone
from typing import Iterable

log = logging.getLogger(__name__)


class S3Egress:
    def __init__(
        self,
        bucket: str,
        vendor: str,
        prefix: str = "audit",
        s3_client=None,
    ):
        self._bucket = bucket
        self._vendor = vendor
        self._prefix = prefix.strip("/")
        if s3_client is not None:
            self._s3 = s3_client
        else:
            import boto3  # deferred so the module imports without boto3

            self._s3 = boto3.client("s3")

    def send(self, events: Iterable[dict]) -> int:
        materialized = list(events)
        if not materialized:
            return 0

        body = self._serialize(materialized)
        key = self._object_key()

        self._s3.put_object(
            Bucket=self._bucket,
            Key=key,
            Body=body,
            ContentType="application/x-ndjson",
            ContentEncoding="gzip",
            ServerSideEncryption="AES256",
            Metadata={"vendor": self._vendor},
        )
        log.info(
            "%s: wrote %d events to s3://%s/%s (%d bytes gzipped)",
            self._vendor,
            len(materialized),
            self._bucket,
            key,
            len(body),
        )
        return len(materialized)

    def _serialize(self, events: list[dict]) -> bytes:
        buf = io.BytesIO()
        with gzip.GzipFile(fileobj=buf, mode="wb") as gz:
            for ev in events:
                gz.write(json.dumps(ev, separators=(",", ":")).encode("utf-8"))
                gz.write(b"\n")
        return buf.getvalue()

    def _object_key(self) -> str:
        now = datetime.now(timezone.utc)
        run_id = uuid.uuid4().hex[:12]
        return (
            f"{self._vendor}/{self._prefix}/"
            f"{now:%Y/%m/%d/%H}/"
            f"{now:%Y%m%dT%H%M%SZ}-{run_id}.jsonl.gz"
        )

"""Firestore-backed forwarder state store, namespaced by vendor."""

from __future__ import annotations

from .state import ForwarderState

COLLECTION = "genai_audit_forwarder"
# Legacy doc id from the initial single-vendor deploy. Anthropic store reads
# it as a fallback so an in-place upgrade preserves dedupe history.
_LEGACY_ANTHROPIC_DOC = "state"


class FirestoreStateStore:
    def __init__(self, vendor: str, project: str | None = None):
        from google.cloud import firestore  # deferred so module imports w/o creds

        self.vendor = vendor
        self._client = firestore.Client(project=project)
        self._collection = self._client.collection(COLLECTION)
        self._doc = self._collection.document(f"{vendor}_state")

    def load(self) -> ForwarderState:
        snap = self._doc.get()
        if snap.exists:
            return ForwarderState.from_dict(snap.to_dict())
        if self.vendor == "anthropic":
            # Look for the pre-multi-vendor legacy collection too.
            legacy_collection = self._client.collection("claude_compliance_forwarder")
            legacy = legacy_collection.document(_LEGACY_ANTHROPIC_DOC).get()
            if legacy.exists:
                return ForwarderState.from_dict(legacy.to_dict())
        return ForwarderState()

    def save(self, state: ForwarderState) -> None:
        self._doc.set(state.to_dict())

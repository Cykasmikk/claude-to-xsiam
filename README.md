# claude-xsiam-log-forwarder

Forwards **Claude Compliance API — Activity Feed** events into **Cortex
XSIAM** using the cloud-native ingestion patterns documented and reference-
architected by Palo Alto Networks:

- **AWS:** Lambda → S3 (gzipped JSON-lines) → S3 ObjectCreated → SQS → XSIAM
  pulls via cross-account IAM role with external ID. Mirrors the Palo-published
  [`terraform-umbrella-s3-to-xsiam-ingestion-module`](https://github.com/PaloAltoNetworks/terraform-umbrella-s3-to-xsiam-ingestion-module).
- **GCP:** Cloud Function → Pub/Sub topic → XSIAM pulls via dedicated pull
  subscription with a service-account credential file.

A direct HTTP-Collector path is included as a non-default fallback.

There is no native Anthropic integration in XSIAM, and no Anthropic-published
XSIAM connector. This repo is the custom forwarder.

> **Spec conformance:** The Compliance API client conforms to **Rev J,
> 2026-04-20** of the *Compliance API: Activity Feed, Chats, Files,
> Organizations, Users, and Projects* spec PDF (distributed by Anthropic to
> Enterprise customers with the Compliance API enabled). The endpoint path,
> query parameters, response shape, and Activity object schema are all
> verified against the PDF; nothing is guessed.

## What this captures vs. what it does not

The Compliance API records **activity** events: authentication (sign-in/SSO,
SCIM provisioning), administrative actions (workspace lifecycle, API key
lifecycle, RBAC, SSO config), resource activity (chats, files, projects,
skills), and platform events (rate-limit changes, usage report access).

It does **not** include inference activity — i.e. user prompts, model
responses, or tool-call payloads. Per Rev J:

| Source | Audit (this repo) | Inference content |
|---|---|---|
| Claude.ai chats / projects / files | metadata only via Activity Feed | Use the *Compliance API content endpoints* (chats / files / projects) — not implemented here, separate scope |
| Cowork / Claude Code | (limited) | [Cowork OpenTelemetry](https://support.claude.com/en/articles/14477985-monitor-claude-cowork-activity-with-opentelemetry) — sibling pipeline |
| Console / Claude API | full Activity Feed coverage | n/a |

Pair this forwarder with Cowork OTel for end-to-end SOC visibility. The two
feeds correlate by the user account identifier shared between them.

## Architecture

### AWS — native (default)

```
       every 5 min
   ┌─────────────┐    ┌──────────────┐   PutObject    ┌────────────┐
   │ EventBridge │ ─▶ │   Lambda     │ ─────────────▶ │ S3 audit   │
   └─────────────┘    │  forwarder   │                │   bucket   │
                     └──────┬────────┘                └─────┬──────┘
                            │ Compliance API                │ ObjectCreated
                            ▼                               ▼
                    ┌────────────────┐               ┌──────────────┐
                    │ api.anthropic  │               │  SQS queue   │
                    │ /v1/compliance │               └──────┬───────┘
                    │  /activities   │                      │ XSIAM polls
                    └────────────────┘                      ▼
                                                  ┌──────────────────┐
                                                  │  Cortex XSIAM    │
                                                  │   (assumed role  │
                                                  │   + external ID) │
                                                  └──────────────────┘
```

### GCP — native (default)

```
       every 5 min
   ┌─────────────┐    ┌────────────────┐    publish    ┌────────────────┐
   │  Scheduler  │ ─▶ │ Cloud Function │ ────────────▶ │  audit topic   │
   └─────────────┘    │   forwarder    │               └────────┬───────┘
                     └──────┬──────────┘                        │
                            │ Compliance API                    ▼
                            ▼                          ┌────────────────┐
                    ┌────────────────┐                 │ XSIAM-bound    │
                    │ api.anthropic  │                 │  subscription  │
                    │ /v1/compliance │                 └────────┬───────┘
                    │  /activities   │                          │ XSIAM pulls
                    └────────────────┘                          ▼
                                                      ┌──────────────────┐
                                                      │  Cortex XSIAM    │
                                                      │  (SA credential  │
                                                      │   JSON file)     │
                                                      └──────────────────┘
```

### Idempotency model

Per Rev J, every Activity object carries a stable `id` (`activity_xxx`), so
dedupe keys directly off that ID. Each tick:

1. Loads prior **watermark** (latest `created_at` ever forwarded) and a
   bounded set of **recent activity IDs**.
2. Queries `created_at.gte = watermark - 5min`, `created_at.lte = now` to
   absorb clock skew and out-of-order delivery.
3. Drops events whose `id` is already in `recent_ids`.
4. Forwards the survivors to the configured egress sink.
5. Persists advanced watermark + refreshed ID set **only after** the egress
   sink ACKs. A crash mid-batch replays the same window cleanly.

Per Rev J the Activity Feed is queryable within ~1 minute of the actual
event, so the 5-minute overlap is generous insurance.

## Prerequisites

1. **Claude Enterprise plan** (Compliance API is GA on Enterprise, excluding
   Public Sector orgs).
2. **Compliance API enabled** for your organization. The path differs by
   product surface:
   - **Claude.ai:** Primary Owner enables it under *Org settings → Data and
     Privacy → Compliance API*.
   - **Console / API:** an org admin requests enablement via your Anthropic
     account team.
3. **An API key** with Activity Feed access. Per Rev J:
   - **Admin key** (`sk-ant-admin01-...`), provisioned via *Console → Settings
     → Admin keys*. When Compliance API is enabled, Admin keys are
     automatically granted the `read:compliance_activities` scope. **This is
     the right key for SOC audit forwarding**.
   - **Compliance Access Key** (`sk-ant-api01-...`), provisioned via *Claude.ai
     → Org settings → Data and Privacy → Compliance access keys*. Carries
     scoped access — needs `read:compliance_activities` for this forwarder.
     Required if you also want to fetch chat/file/project content (separate
     scope, not used by this forwarder).
4. **XSIAM data source onboarding info** — depends on which path:
   - **AWS:** the AWS account ID of your XSIAM tenant (shown in the *Settings
     → Data Sources → Add → Amazon S3 generic logs* onboarding screen). After
     `terraform apply`, paste the role ARN, external ID, and SQS URL back
     into that screen.
   - **GCP:** none in advance. After `apply`, generate a SA key for the
     output service account and paste it (with the subscription name) into
     the *GCP Pub/Sub* data source onboarding screen.
   - **HTTP fallback:** an HTTP Collector configured as a Custom App with its
     tenant URL and auth token.
5. Terraform ≥ 1.6.

## Repository layout

```
src/
  main.py                 GCP Cloud Function entrypoint (re-exports handler)
  requirements.txt        GCP Cloud Build installs these at deploy time
  forwarder/
    core.py               fetch → forward → checkpoint loop
    claude_client.py      Compliance API Activity Feed client (Rev J)
    state.py              ForwarderState dataclass + StateStore protocol
    state_aws.py          DynamoDB state backend
    state_gcp.py          Firestore state backend
    aws_handler.py        Lambda entrypoint (uses egress.s3)
    gcp_handler.py        Cloud Function handler (uses egress.pubsub)
    egress/
      __init__.py         Egress protocol
      s3.py               AWS native: gzipped JSON-lines to S3
      pubsub.py           GCP native: publish to Pub/Sub topic
      http.py             Fallback: direct POST to XSIAM HTTP Collector
terraform/aws/            Lambda + EventBridge + S3 + SQS + cross-account
                          IAM role + DynamoDB + Secrets Manager
terraform/gcp/            Cloud Function + Scheduler + audit Pub/Sub topic
                          + XSIAM-bound subscription + SA + Firestore +
                          Secret Manager
tests/smoke.py            Deterministic smoke tests (no AWS/GCP creds needed)
.github/workflows/ci.yml  Python syntax + smoke + terraform validate
```

## Deploy — AWS

```bash
cd terraform/aws
terraform init
terraform apply \
  -var "anthropic_admin_api_key=sk-ant-admin01-..." \
  -var "xsiam_aws_account_id=<XSIAM tenant AWS account ID from XSIAM UI>"
```

After `apply`, paste these outputs into the XSIAM *Amazon S3 generic logs*
data source onboarding screen:

| XSIAM field    | Terraform output       |
|----------------|------------------------|
| Role ARN       | `xsiam_role_arn`       |
| External ID    | `xsiam_external_id`    |
| SQS queue URL  | `xsiam_sqs_url`        |
| Bucket         | `audit_bucket`         |

Get the external ID with:
```bash
terraform output -raw xsiam_external_id
```

## Deploy — GCP

```bash
cd terraform/gcp
terraform init
terraform apply \
  -var "project_id=my-soc-project" \
  -var "region=us-central1" \
  -var "anthropic_admin_api_key=sk-ant-admin01-..."
```

After `apply`:

1. Generate a JSON key for the XSIAM service account (intentionally **not**
   created by Terraform — keys in TF state are an audit smell):

   ```bash
   gcloud iam service-accounts keys create xsiam-credentials.json \
     --iam-account=$(terraform output -raw xsiam_service_account_email)
   ```

2. In the XSIAM *GCP Pub/Sub* data source onboarding screen, paste:

   | XSIAM field       | Source                                          |
   |-------------------|-------------------------------------------------|
   | Subscription name | `terraform output xsiam_audit_subscription`     |
   | Service account   | the contents of `xsiam-credentials.json`        |

3. Delete the local key file once XSIAM has it.

## Verifying ingestion in XSIAM

After the first scheduled run:

```xql
dataset = <your_audit_dataset>
| filter type and id   // Compliance API Rev J Activity object fields
| sort desc _time
| limit 50
```

Each row is one Activity object: `id`, `created_at`, `type` (e.g.
`claude_chat_created`, `sso_login_succeeded`, `platform_api_key_created`),
`organization_id`, `organization_uuid`, and a nested `actor` object whose
`actor.type` discriminates user vs. API key vs. SCIM sync vs.
unauthenticated user vs. Admin API key.

Common SOC queries:

```xql
// Audit all Admin API key creations across the org
dataset = <your_audit_dataset>
| filter type = "admin_api_key_created"
| fields _time, actor.type, actor.user_id, admin_api_key_id, scopes
```

```xql
// SSO failure spike detection
dataset = <your_audit_dataset>
| filter type in ("sso_login_failed", "magic_link_login_failed")
| comp count() by bin(_time, 5m)
```

```xql
// Compliance API self-audit (every Compliance API request is itself logged)
dataset = <your_audit_dataset>
| filter type = "compliance_api_accessed"
| fields _time, actor.api_key_id, url, status_code
```

## Tuning

| Variable                                    | Default | Notes                                              |
|---------------------------------------------|---------|----------------------------------------------------|
| `schedule_minutes`                          | `5`     | Rev J: events queryable within ~1 min of occurrence |
| `initial_lookback_minutes`                  | `60`    | First-run window; subsequent runs use saved state  |
| `OVERLAP_SECONDS` (code)                    | `300`   | Re-query margin for clock skew at boundary         |
| `MAX_RECENT_IDS` (code)                     | `10000` | Bound on dedupe state size                         |
| `bucket_object_retention_days` (AWS)        | `365`   | S3 lifecycle expiry (Activity Feed itself: 6 years) |
| `subscription_message_retention_seconds` (GCP) | `604800` | 7-day buffer if XSIAM is down                  |
| `COMPLIANCE_API_PATH` (env, both clouds)    | `/v1/compliance/activities` | Override for future spec revisions     |

## Operational notes

- **First run** with no saved state pulls only `initial_lookback_minutes` so
  you don't accidentally backfill 6 years of events into XSIAM.
- **Failure mode (egress)**: any error from the egress sink aborts before
  the watermark advances. Dedupe (by activity ID) handles the overlap on
  next tick.
- **Failure mode (Anthropic)**:
  - 401/403 raises with explicit guidance to verify Compliance API enablement
    and `read:compliance_activities` scope.
  - 404 raises with the Rev J path documented and `COMPLIANCE_API_PATH` env
    var override.
  - 400 surfaces the structured `error.message` from the API verbatim.
- **Self-audit:** every Compliance API request is itself logged as a
  `compliance_api_accessed` Activity event in the next tick. Useful for the
  SOC to detect anomalous Compliance API access patterns.
- **Cost:** at the default 5-min cadence with low audit volume, AWS and GCP
  free tiers cover this entirely.

## Falling back to the HTTP Collector path

If you can't (or don't want to) use the native S3/Pub-Sub paths, the
`src/forwarder/egress/http.py` sink POSTs directly to an XSIAM HTTP
Collector. Swap the egress instance in your handler:

```python
# in aws_handler.py or gcp_handler.py
from .egress.http import HttpEgress, HttpEgressConfig

egress = HttpEgress(HttpEgressConfig(
    url=os.environ["XSIAM_COLLECTOR_URL"],
    token=_secret(os.environ["XSIAM_TOKEN_SECRET_ARN"]),
))
```

Caveats: the auth header name and gzip support are not authoritatively
documented by Palo for the HTTP Collector — verify against your tenant's
collector configuration screen. The native paths avoid these unknowns.

## References

- **Anthropic**
  - [Compliance API access](https://support.claude.com/en/articles/13015708-access-the-compliance-api)
  - [Compliance API announcement](https://claude.com/blog/claude-platform-compliance-api)
  - [Admin API overview](https://platform.claude.com/docs/en/build-with-claude/administration-api)
  - [Cowork OpenTelemetry](https://support.claude.com/en/articles/14477985-monitor-claude-cowork-activity-with-opentelemetry)
- **Palo Alto / Cortex XSIAM**
  - [External log sources overview](https://docs-cortex.paloaltonetworks.com/r/Cortex-XSIAM/Cortex-XSIAM-Documentation/Visibility-of-logs-and-alerts-from-external-sources)
  - [Ingest Logs and Data from a GCP Pub/Sub](https://docs-cortex.paloaltonetworks.com/r/Cortex-XSIAM/Cortex-XSIAM-Documentation/Ingest-Logs-and-Data-from-a-GCP-Pub/Sub)
  - [Ingest generic logs from Amazon S3](https://docs-cortex.paloaltonetworks.com/r/Cortex-XSIAM/Cortex-XSIAM-Documentation/Ingest-generic-logs-from-Amazon-S3)
  - [PaloAltoNetworks/terraform-umbrella-s3-to-xsiam-ingestion-module](https://github.com/PaloAltoNetworks/terraform-umbrella-s3-to-xsiam-ingestion-module) (reference architecture)
- **AWS**
  - [Lambda runtimes](https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html)
- **GCP**
  - [Cloud Functions Python runtime](https://cloud.google.com/functions/docs/concepts/python-runtime)

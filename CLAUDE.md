# CLAUDE.md — Agent Gateway project

Context for AI sessions working in this folder. Read README.md first for the file inventory and architecture summary; this file covers conventions, editing rules, and hard-won facts that aren't obvious from the files themselves.

## What this project is

Documentation + diagrams + an agent-executable runbook + **a real deployed implementation** of one flow: an APM-lookup agent (Vertex AI Agent Engine / ADK, with Agent Identity) that queries Cloud SQL for PostgreSQL through the Google-managed Cloud SQL MCP server, governed end-to-end by Agent Gateway (Gemini Enterprise Agent Platform).

## Live deployment state (built 2026-08-18, project `schwab-agent-poc`)

**Read `BUILD-REPORT.md` first when touching the deployment** — it has every resource name, the agent principal, all IAM grants, validation evidence, and the deviations list. Quick facts:
- Agent code lives in `apm-lookup-agent/` (agents-cli scaffold, ADK 2.7.1). Deploy: `uv run python -m app.app_utils.deploy --project schwab-agent-poc --location us-east4 --agent-identity --agent-gateway ...` (full command in BUILD-REPORT). Each deploy ≈ 6 min.
- Engine `4353476707760472064` (us-east4), **working end-to-end in audit mode**: Agent Identity → gateway → Cloud SQL MCP `execute_sql_readonly` → `apm_db.apm_assets` (8 seeded rows incl. `APM999999` injection test row).
- **Model Armor: LIVE, tuned posture** — MCP/database path SANITIZES (PII redacted in-line `[EMAIL_ADDRESS]`, injection text delivered as data + logged; de-identify template = sanitize-and-allow, hard-block knob documented in runbook §8.6); model path (`AI_PLATFORM` floor) INSPECT-ONLY because our own defensive system instruction scores HIGH on the PI filter and block mode there false-positives legit queries; `GOOGLE_MCP_SERVER` floor in block. The gateway CONTENT_AUTHZ httpRules MUST exclude `application/grpc` AND `:generateContent`/`:streamGenerateContent` paths (grpc exclusion prevents killing all gRPC/deploys; model-path exclusion prevents the self-blocking trap). Grants on SAME-PROJECT service agents (`service-82648816720@gcp-sa-dep`, `gcp-sa-modelarmor`, `gcp-sa-aiplatform-re`) — never the tenant SA on the gateway card (DRS blocks it). Unauthorized callout fails CLOSED for ALL egress; recovery = delete the authz policy.
- **Memory Bank: wired via two mandatory fixes** — explicit `memory_service_builder` (AdkApp default silently used the in-memory stub) AND `generation_trigger_config: {generation_rule: {idle_duration: "60s"}}` in the callback's `add_events_to_memory` custom_metadata (untriggered ingest auto-flushes after 24 HOURS — looks like "memories never appear"). Immediate demo memory: POST `memories:generate` with `vertexSessionSource`.
- **Semantic policies: built, blocked at PSC.** Engine ACTIVE, policies `apm-sql-readonly`/`apm-agent-purpose` created (note: `--agent` needs FULL resource path), VPC+DNS+attachment ready, configs in `infra/`. Blocker (verified genuine): org policy `compute.disablePrivateServiceConnectCreationForConsumers` = denyAll; needs org-admin exception, then runbook Phase 8b.
- **Telemetry uploads need bucket `gs://PROJECT_ID`** + agent `storage.objectUser`, or runtime logs `OSError: Forbidden` per turn.
- **Runbook Appendix A** has the complete reproduction inventory: 23 APIs, the full IAM matrix, resource list, and the symptom→cause cheat sheet. Keep it current — it's the client-site handoff.
- Debug operations (`debug_env`/`debug_probe`/`debug_mcp`) were removed and the cleanup deployed. **Memory Bank fully verified** incl. cross-session recall changing behavior; ingress-filter false positives on "remember that…" phrasing were part of that investigation.
- The four egress authorization layers (all bit us): registry hostname entries → `roles/iap.egressor` → **`roles/mcp.toolUser`** (undocumented) → Cloud SQL roles + Postgres GRANTs. Agent identities can't be Cloud SQL IAM DB users; the agent uses `apm_reader` + `passwordSecretVersion`.
- Local dev: `agents-cli run "prompt"` in `apm-lookup-agent/` (needs ADC = abdur.raja@intuitive.ai — beware `gcloud auth application-default login` account drift). Eval: `agents-cli eval run` (4 cases, must stay 5.0).
- The `.claude/skills/google-agents-cli-*` skills are installed workspace-level — load `google-agents-cli-workflow` before agent code changes, `-eval` before evals, `-deploy` before deployment changes.

## Editing rules

1. **`diagrams/agent-gateway-architecture.html` is the single source of truth for diagrams.** The PNGs are renders of it. Never edit a PNG-related fact without editing the HTML; after any HTML figure change run `./diagrams/render-diagrams.sh` to regenerate all three PNGs, then visually verify the output (Read the PNGs).
2. **Keep the three tellings consistent.** Most facts appear in three places: a diagram, the policy table/prose in the HTML, and `agent-gateway-walkthrough.md`. When one changes, update all three. (Example of past drift: the Model Armor basic-vs-advanced SDP distinction had to be added to diagram cards, the table, and the script separately.)
3. **Diagram conventions** (all figures share these):
   - Inline SVG, hand-authored, in the HTML. Shared `<symbol>` icon defs live in a hidden SVG at the top of `<main>`; markers `arB` (blue), `arM` (muted), `arR` (red).
   - Styling via CSS classes on tokens (`.z` zone, `.c` card, `.cB` blue-stroked card, `.t1/.t2/.t2b` text tiers, `.fl` flow arrow, `.rt` dashed return, `.dn` red deny, `.redbar` deny bar). Light theme only, deliberate (Google-diagram look).
   - **Icons:** official Google Cloud icons are embedded as symbols `o-sql`, `o-iam`, `o-iap`, `o-vertex` (extracted from the official icon zip, classes converted to inline fills to avoid `cls-N` collisions). Agent Identity (`i-id`), Agent Gateway (`i-gw`), Model Armor (`i-shield`), Agent Registry (`i-reg`), MCP (`i-mcp`), Semantic (`i-sem`) are **custom schematics — Google has published no official icons for these products** (checked Aug 2026; icon set predates the agent platform). `i-id` is styled in official-IAM blues on purpose (user rejected the earlier green). The gateway diamond `i-gw` appears on figure-1 cards AND on both pipeline container titles — keep that pairing.
   - The user wants the Agent Identity icon consistent everywhere it appears (figure 1 chip + figure 2 stage 1).
4. **PNG rendering:** `diagrams/render-diagrams.sh` extracts each `<figure>` SVG into a standalone page and screenshots with headless Chrome at `--force-device-scale-factor=2`. Figure order in the HTML maps to output names — if you add/reorder figures, update `NAMES` in the script.
5. **Runbook edits:** `agent-gateway-setup-runbook.md` is written for a *coding agent* to execute (ground rules, VERIFY blocks, HUMAN ACTION gates, Phase 10 human-gated). Preserve that structure — don't turn it back into prose. Commands in it were verified against Google docs Aug 2026; if you touch a command, re-verify against the linked doc (these CLIs drift).

## Decisions already made (don't relitigate without the user)

- Local HTML file, **not** a claude.ai artifact (user explicitly switched).
- Egress pipeline has **five** stages — Service Extensions was removed at user request.
- Cloud Logging/Trace card was removed from figure 1 (user tracks observability separately).
- Semantic policies are shown **with concrete examples** everywhere (SELECT-only, must filter on APM ID, no read→send combos, no `SELECT *`), not as an abstract label.
- Ingress figure deliberately places authorization *outside* the gateway box ("Authorization at the destination") — that asymmetry is the point; don't "fix" it.

## Facts that took research (all doc-verified Aug 2026)

- Agent Gateway lives under **Gemini Enterprise Agent Platform** (`gcloud network-services agent-gateways import`, YAML with `governedAccessPath: AGENT_TO_ANYWHERE | CLIENT_TO_AGENT`).
- Egress enforcement = IAP evaluating IAM at runtime; the gateway checks `iap.webServiceVersions.egressViaIAP` → only `roles/iap.egressor` carries it; granted via `gcloud iap web set-iam-policy --resource-type=agent-registry` (replaces policy — always fetch-merge-set).
- **No IAP on ingress**; ingress = OAuth 2.0 via Auth Manager + Model Armor; authz enforced by IAM at the Agent Engine endpoint. Ingress Model Armor covers `streamQuery` for ADK agents.
- Google-managed MCP servers **auto-register in Agent Registry** when their API is enabled. Cloud SQL MCP endpoint `https://sqladmin.googleapis.com/mcp`, narrower toolsets `/mcp/readonly`, `/mcp/query_execution`.
- Gateway attach happens in the agent deployment config: `agent_engines.create(config={"agent_gateway_config": {...}, "identity_type": AGENT_IDENTITY})`; retrofit via REST PATCH `updateMask=spec.deploymentSpec.agentGatewayConfig`.
- Agent principal format: `principal://agents.global.org-ORG_ID.system.id.goog/resources/aiplatform/.../reasoningEngines/ENGINE_ID` (copy from Console → Agent Engine → Deployments → Identity).
- Model Armor: basic SDP = detect/block only; redaction = advanced SDP with `--advanced-config-inspect-template` + `--advanced-config-deidentify-template`. Same-region constraint with the gateway.
- Cloud SQL: `cloudsql.iam_authentication=on` (`--database-flags` replaces the whole set!), `data_api_access=ALLOW_DATA_API` (console/`update_instance` tool — no gcloud flag), IAM DB username drops `.gserviceaccount.com`, `execute_sql` has a 30s timeout and runs ANY SQL the DB user is granted → `GRANT SELECT` only is the real write-protection.
- Gateway limits: no VPC-SC on the gateway itself (agent identities in VPC-SC rules are separate, preview), publicly-trusted certs only, 5,000 registered resources/gateway.

## User preferences observed

- Wants accuracy over speed — asks "is that actually right?" follow-ups; be precise about product boundaries (e.g. Agent Identity *is* stage 1, IAM×IAP *consumes* it) and label inference vs. documented fact.
- Prefers concrete examples over abstract labels in diagrams.
- Deliverables as local files in this folder (diagrams as PNG exports for sharing).
- When told an icon/label is wrong, fix it in **every** figure, not just the one mentioned.

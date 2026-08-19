# Agent Gateway — APM Lookup Agent

A **working, field-tested reference implementation** of a governed AI agent on Google Cloud's Gemini Enterprise Agent Platform: an agent (Vertex AI Agent Engine, ADK) that receives an APM ID, queries **Cloud SQL for PostgreSQL** through the **Google-managed Cloud SQL MCP server**, and returns results — with every hop authenticated, authorized, content-screened, and logged. Built and validated end-to-end on `schwab-agent-poc` (Aug 2026), including live-verified **blocking** of prompt-injection attempts at multiple layers.

## The architecture in one paragraph

Three products stack; they don't compete. **Agent Identity** answers *who is calling* — each deployed agent gets its own SPIFFE ID and auto-rotated X.509 certificate, making it a first-class IAM principal (no API keys anywhere in the flow). **Agent Gateway** answers *is this call allowed* — a managed proxy all agent traffic crosses, enforcing registry allowlists, IAM×IAP, and content policies. **Model Armor** answers *is the content safe* — screening at **three points**: agent ingress (user↔agent, via floor settings — feeds the console Security tab), gateway egress (agent↔database, via CONTENT_AUTHZ callout — catches poisoned rows, redacts PII), and inside Google-managed MCP servers (floor settings, defense-in-depth). **Semantic governance policies** add natural-language runtime rules (SELECT-only, must filter on the requested APM ID) evaluated at the model boundary. The real write-protection is at the bottom: a `SELECT`-only database user whose password lives in Secret Manager and is only ever passed by reference.

## Current deployment state (schwab-agent-poc)

| Layer | Status |
|---|---|
| Agent + Agent Identity + gateway routing | ✅ live, validated |
| Registry egress allowlist (default-deny proven) | ✅ live |
| IAM × IAP authorization | ✅ DRY_RUN (audit) — flip after log review |
| Model Armor (all 3 points) | ✅ **BLOCK mode, live-verified** (403 on injection; `[EMAIL_ADDRESS]` redaction in-line) |
| Memory Bank + Sessions + telemetry | ✅ wired (see runbook 5b — two non-obvious fixes required) |
| Semantic governance policies | ⏸ built end-to-end; blocked by org policy `compute.disablePrivateServiceConnectCreationForConsumers` (one org-admin exception, then ~15 min) |
| Deny policy + PAB hardening | ⏸ org-admin |

## Files

| File | What it is |
|---|---|
| **`agent-gateway-setup-runbook.md`** | **The reproduction guide.** 10 field-tested phases for a coding agent supervised by DevOps, plus **Appendix A**: complete API list, the full IAM matrix (every principal → role → why), resource inventory, and a symptom→cause cheat sheet for every failure we hit. Start here to rebuild at a client. |
| `BUILD-REPORT.md` | Evidence record of the POC build: every resource name, validation results, and the 13+ documented deviations from Google's docs. |
| `apm-lookup-agent/` | The agent source (agents-cli scaffold, ADK): MCP toolset, Memory Bank wiring, the deploy CLI with `--agent-identity`/`--agent-gateway`. |
| `diagrams/agent-gateway-architecture.html` + 3 PNGs | Architecture diagrams (end-to-end flow, egress pipeline, ingress with 3-legged OAuth). `./diagrams/render-diagrams.sh` regenerates the PNGs. |
| `agent-gateway-walkthrough.md` | Presenter script (~7–9 min) narrating the diagrams, with anticipated Q&A. |
| `infra/` | All applied infrastructure configs — gateway YAML, IAP/Model Armor/SGP authz extensions + policies, IAM policy JSONs, org-policy overrides — each indexed in `infra/README.md` with its apply command and runbook phase. |
| `CLAUDE.md` | Context for AI-assisted sessions: conventions, live state, and the hard-won operational lessons. |

## Deploying it

**→ `DEPLOY.md`** is the start-here deploy guide. Two scenarios, each with copy-paste commands:
- **Scenario A** — redeploy to the existing `schwab-agent-poc` project (the one custom deploy command + verify).
- **Scenario B** — build fresh in a new project (points to the full runbook + the org-admin prerequisites to request first).

⚠️ Do **not** use `agents-cli deploy` — this is a governed agent and needs the custom deploy script (DEPLOY.md explains why).

## Reproducing this at a client site

1. Fill in **Phase 0** of the runbook (project, org, region, SQL instance/table) and confirm the two scoping questions.
2. Request the **org-admin prerequisites in Appendix A.2 up front** (PSC constraint exception for semantic policies; DRS confirmation; deny/PAB grants) — these were the only things a project owner couldn't self-serve.
3. Hand the runbook to a coding agent (Claude Code) supervised by DevOps — it's written for exactly that, with VERIFY blocks, stop conditions, and human-action gates.
4. Expect the platform quirks in **Appendix A.4** — every failure signature we hit is mapped to its cause and fix. The five most expensive discoveries are summarized at the top of the runbook.

## The five discoveries that cost the most time (short version)

1. The gateway's egress allowlist is **hostname SERVICE entries in Agent Registry** — including Google's own platform hosts (Resource Manager, telemetry), or new deployments crash at startup.
2. **`roles/mcp.toolUser`** is required for any Google MCP `tools/call` — undocumented, bare-403 failure.
3. **Agent identities can't be Cloud SQL IAM database users** — use a read-only DB user + `passwordSecretVersion` (Secret Manager reference).
4. **CONTENT_AUTHZ policies must exclude `application/grpc`** or they break every gRPC stream through the gateway (deploys fail, serving revision survives — maximally confusing).
5. Model Armor grants go to the **same-project-number service agents**, never the tenant-project SA the gateway card displays (Domain Restricted Sharing blocks those); and an unauthorized callout **fails closed for all traffic**.

## Reference docs

[Agent Gateway](https://docs.cloud.google.com/gemini-enterprise-agent-platform/govern/gateways/agent-gateway-overview) · [Set up](https://docs.cloud.google.com/gemini-enterprise-agent-platform/govern/gateways/set-up-agent-gateway) · [Agent Identity](https://docs.cloud.google.com/iam/docs/agent-identity-overview) · [Model Armor + Gateway](https://docs.cloud.google.com/model-armor/model-armor-agent-gateway-integration) · [Semantic governance](https://docs.cloud.google.com/gemini-enterprise-agent-platform/govern/policies/configure-semantic-governance) · [Memory Bank ingest](https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale/memory-bank/ingest-events) · [Cloud SQL MCP](https://docs.cloud.google.com/sql/docs/postgres/use-cloudsql-mcp) · [Codelab repo (gateway configs)](https://github.com/GoogleCloudPlatform/cloud-networking-solutions)

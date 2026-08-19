# How to deploy this agent

Read this before running anything. **Do NOT use plain `agents-cli deploy`** — this is a *governed* agent (Agent Identity + Agent Gateway + Model Armor + Memory Bank), and the stock deploy command skips all of that and produces a broken, ungoverned agent. Use the custom deploy script below.

Pick your scenario:

---

## Scenario A — Redeploy to the EXISTING project (`schwab-agent-poc`)

The infrastructure (gateway, registry, IAM, Model Armor, DB) is already built. You just want to push an updated agent, or redeploy as-is.

### One-time local setup
```bash
# 1. Auth (you need access to schwab-agent-poc; ask Abdur)
gcloud auth login
gcloud auth application-default login          # the deploy uses ADC
gcloud config set project schwab-agent-poc

# 2. Tools + deps
uv tool install google-agents-cli
cd apm-lookup-agent
uvx google-agents-cli setup                    # installs the ADK skills
agents-cli install                             # installs python deps into .venv
```

### Test locally first (optional but recommended)
```bash
agents-cli run "Look up APM001234"             # hits the real Cloud SQL MCP server via your ADC
```

### Deploy (the REAL command — not `agents-cli deploy`)
```bash
uv run python -m app.app_utils.deploy \
  --project schwab-agent-poc \
  --location us-east4 \
  --agent-identity \
  --agent-gateway "projects/schwab-agent-poc/locations/us-east4/agentGateways/apm-agent-gateway" \
  --set-env-vars "APP_GOOGLE_CLOUD_PROJECT=schwab-agent-poc,GOOGLE_CLOUD_LOCATION=global,GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES=false"
```
Takes ~5–6 min. It **updates the existing engine in place** (matches by display name `apm-lookup-agent`), so identity, gateway wiring, and Memory Bank config are preserved.

### Verify
```bash
# quick query against the deployed agent (needs $TOKEN from: gcloud auth application-default print-access-token)
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "https://us-east4-aiplatform.googleapis.com/v1beta1/projects/schwab-agent-poc/locations/us-east4/reasoningEngines/4353476707760472064:streamQuery" \
  -d '{"class_method":"stream_query","input":{"user_id":"deploy-check","message":"Look up APM001234"}}'
```
Or open the console playground: Vertex AI → Agent Engine → `apm-lookup-agent`.

### Gotchas (all field-verified — full list in `agent-gateway-setup-runbook.md` Appendix A.4)
- **A deploy can fail with "failed to be updated" while the old version keeps serving.** That's normal — failed revisions don't replace the live one. Check the runtime logs for the real error before retrying (usually a startup gRPC call to an unregistered host).
- **Don't add new outbound calls** to the agent without registering the destination hostname in Agent Registry first, or the gateway blocks it.
- **`gcloud auth` account drift**: if you have multiple accounts, `gcloud` may silently switch. If you get a 403 on query, run `gcloud config set account <you>@…` and re-login.

---

## Scenario B — Build fresh in a NEW project (client site, etc.)

You are standing up the whole thing from zero in a different GCP project. This is a bigger job — 10 phases, ~20 APIs, a specific IAM matrix, and a few org-policy prerequisites.

**Two ways to do it:**
- **Scripted (recommended):** `scripts/setup-governed-agent.sh` — the runbook as one idempotent, phased script. Edit the config block, run `preflight`, then run phases one at a time verifying each (`apis` → `sql` → `registry` → `gateway` → `deploy` → `iam` → `authz` → `modelarmor` → `validate`). It auto-captures the agent principal after deploy and STOPS at the steps that need you (Data API toggle, DB reader user) or an org admin (semantic policies). See `scripts/README.md`.
- **By hand / to understand each step:** `agent-gateway-setup-runbook.md` — step-by-step with copy-paste commands, verification after each phase, and a symptom→cause cheat sheet (Appendix A.4). Start by filling in **Phase 0**.

The script covers the base build (identity + gateway + IAM + Model Armor); semantic-governance policies and the enforce-mode flip stay in the runbook (they're org-gated / post-audit).

**Before you start, request these from a GCP org admin** (a project owner cannot self-serve them — see runbook Appendix A.2):
1. Exception to `constraints/compute.disablePrivateServiceConnectCreationForConsumers` for the project (needed for semantic-governance policies).
2. Confirmation that domain-restricted-sharing (`iam.allowedPolicyMemberDomains`) permits grants to same-project `gcp-sa-*` service agents.
3. (Optional hardening) org-level rights for the IAM deny policy + Principal Access Boundary.

The `infra/` folder has the exact gateway/authz/IAM config files that were applied — substitute your project/region.

---

## What you're deploying (30-second orientation)

`apm-lookup-agent/` is an ADK agent (scaffolded with `agents-cli`) that takes an APM ID, queries Cloud SQL for PostgreSQL through the Google-managed Cloud SQL MCP server, and summarizes the record. Everything that makes it *governed* — its own cryptographic identity, all traffic routed through Agent Gateway, content screened by Model Armor, a read-only DB user — is wired at deploy time (Scenario A's command) on top of infrastructure that already exists (Scenario B builds it). Architecture diagrams: `diagrams/`. Full context: `README.md` → `BUILD-REPORT.md`.

> **Note:** the auto-generated `apm-lookup-agent/README.md` is stock scaffold boilerplate and its "Deployment" section (`agents-cli deploy`) is **wrong for this agent** — ignore it and use this file.

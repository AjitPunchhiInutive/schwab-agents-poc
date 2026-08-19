# Build Report — APM Lookup Agent on Agent Gateway (schwab-agent-poc)

**Status: WORKING END-TO-END — final tuned enforcement posture (2026-08-19).**
- **MCP path (gateway CONTENT_AUTHZ + GOOGLE_MCP_SERVER floor): SANITIZE-AND-LOG** — poisoned rows arrive with PII redacted in-line (`[EMAIL_ADDRESS]`), injection text delivered as data (agent verified resilient), full findings logged. De-identify template semantics = sanitize-and-allow; for HARD-BLOCK of poisoned rows use a separate response template without deidentify (documented client policy knob in the runbook §8.6).
- **Model path (`AI_PLATFORM` floor): INSPECT-ONLY** — block mode there false-positives on our own defensive system instruction (scores HIGH on the PI filter; worse with injected memories). User-prompt attacks are logged; agent refusal + MCP-path screening contain them.
- IAP remains DRY_RUN pending audit review.
- **Memory Bank: FULLY VERIFIED end-to-end** — write via agent callback, extraction, cross-session recall that changed behavior ("with criticality listed first, as requested"). Two mandatory fixes: explicit `memory_service_builder` (AdkApp default silently used the in-memory stub) + `generation_trigger_config` idle trigger (plain `add_session_to_memory` buffers 24h). Ingress-filter false positives on natural "remember that…" phrasing were part of the same investigation. The deployed agent answers APM lookups through the full governed path: Agent Identity → Agent Gateway (egress) → Google-managed Cloud SQL MCP server → Cloud SQL for PostgreSQL, with IAP in DRY_RUN and all traffic logged. Built 2026-08-18.

## What exists now

| Resource | Value |
|---|---|
| Agent Engine | `projects/schwab-agent-poc/locations/us-east4/reasoningEngines/4353476707760472064` (display: `apm-lookup-agent`) |
| Agent Identity | `principal://agents.global.org-203589767236.system.id.goog/resources/aiplatform/projects/82648816720/locations/us-east4/reasoningEngines/4353476707760472064` |
| Agent Gateway | `projects/schwab-agent-poc/locations/us-east4/agentGateways/apm-agent-gateway` (AGENT_TO_ANYWHERE, MCP, registry: global) |
| Authz (DRY_RUN) | ext `apm-gateway-authz-ext` → policy `apm-gateway-authz-policy` (IAP, `iamEnforcementMode: DRY_RUN`) |
| Model Armor | template `apm-egress-template` (us-east4; PI/jailbreak MEDIUM+, malicious URI, **advanced SDP** with `apm-inspect`/`apm-deidentify`, RAI ×4, `INSPECT_ONLY`, logging). Callout extension `apm-gateway-modar-ext` exists; CONTENT_AUTHZ policy **detached** — see "Model Armor status" below |
| SDP templates | `projects/schwab-agent-poc/locations/us-east4/inspectTemplates/apm-inspect` + `deidentifyTemplates/apm-deidentify` (EMAIL, PHONE, SSN, CREDIT_CARD → replace-with-infoType) |
| Database | `apm-validation-db` / `apm_db` / `public.apm_assets` (8 seed rows incl. `APM999999` injection-test row); IAM auth on; `data_api_access=ALLOW_DATA_API` |
| DB reader | Postgres user `apm_reader` (CONNECT/USAGE/SELECT on `apm_assets` only); password in regional secret `apm-reader-east4` |
| Registry endpoints | `sqladmin[.mtls].googleapis.com`, `oauth2.googleapis.com` registered in `global` + `us-east4` |
| Agent code | `apm-lookup-agent/` — ADK 2.7.1, `execute_sql_readonly` toolset, Memory Bank (3 managed topics), telemetry on |
| Secrets | `apm-pg-admin-east4` (postgres admin pw), `apm-reader-east4` (reader pw) — regional, us-east4 |

Agent principal IAM: `iap.egressor` (global agent-registry IAP), `mcp.toolUser`, `cloudsql.instanceUser`, `cloudsql.studioUser`, `secretmanager.secretAccessor` (reader secret only), + runtime roles from deploy (`aiplatform.user`, `serviceusage.serviceUsageConsumer`, `browser`, `cloudapiregistry.viewer`, `logging.logWriter`, `monitoring.metricWriter`).

## Validation results (Phase 9)

- ✅ Happy path: `APM001234` → correct Trade Order Router summary (deployed agent, through gateway).
- ✅ Gateway decode + allow: `gateway_requests` log shows `tools/call execute_sql_readonly` → 200, authz `ALLOWED`.
- ✅ IAP DRY_RUN evaluating: authzPolicyInfo `ALLOWED` on all agent traffic.
- ✅ Registry default-deny proven: sqladmin was blocked (403 `default_denied`) until its hostname was registered.
- ✅ Unknown ID → honest not-found. ✅ Write attempt → refused, no write executed (and `apm_reader` cannot write). ✅ Injection row → content treated as data, flagged as suspicious.
- ✅ Sessions: 26 sessions on the engine (console → Agent Engine → Sessions). ✅ Memory Bank: contextSpec active (3 managed topics). ✅ Telemetry: `GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY=true`; gateway shows `telemetry.mtls.googleapis.com` ALLOWED.
- ✅ Local eval: 4/4 cases at 5.0/5.0 (response quality + policy compliance).

## The four egress authorization layers (all were hit during debugging)

1. **Gateway reachability** — destination hostname must be a registered Agent Registry service (`gcloud alpha agent-registry services create HOST --interfaces=url=https://HOST,...`). Default-deny otherwise.
2. **Gateway authz** — IAP evaluates `iap.webServiceVersions.egressViaIAP` (`roles/iap.egressor` on the agent-registry IAP resource). DRY_RUN now.
3. **MCP invocation** — `mcp.googleapis.com/tools.call`, carried only by **`roles/mcp.toolUser`**. Undocumented in the main gateway docs; error surfaces as a bare 403 on `tools/call`.
4. **Service + database** — `cloudsql.instanceUser`/`studioUser` for the API; Postgres privileges for the DB user.

## Deviations & discoveries (vs. the original runbook)

1. **Google-managed MCP servers auto-register** in Agent Registry (location `global`) when their API is enabled — but that is *catalog* registration only. **Egress hostnames still need explicit service entries** (see layer 1) — the runbook's biggest gap, resolved from Google's `cloud-networking-solutions` codelab repo.
2. **`roles/mcp.toolUser` is required** for any Google MCP `tools/call` (layer 3).
3. **Agent identities cannot be Cloud SQL IAM database users** today: the Data API attempts Postgres login as the 63-char-truncated SPIFFE path, and `sql users create` rejects registering it. **Workaround in place:** dedicated `apm_reader` BUILT_IN user + `passwordSecretVersion` (regional secret) passed in the tool call — the model never sees the password.
4. **Startup crash behind the gateway:** `AdkApp.project_id()` resolves project number→ID via a Resource Manager gRPC call, which gateway egress blocks; only auth errors fail open. **Fix:** override `project_id()` in `AgentEngineApp` (and pass `APP_GOOGLE_CLOUD_PROJECT`; `GOOGLE_CLOUD_PROJECT` is reserved on Agent Engine).
5. **A failed-to-start engine revision goes sticky** — subsequent updates fail without new logs. Fix: delete the engine and create fresh (re-grant IAM to the new principal; its ID changes).
6. **`gcloud model-armor` hits the wrong endpoint** (PERMISSION_DENIED even with `roles/modelarmor.admin`). Regional REST works: `modelarmor.us-east4.rep.googleapis.com`. Also: Model Armor perms are NOT in `roles/owner`.
7. **Regional secrets** need the endpoint override (`api_endpoint_overrides/secretmanager`) and the Data API only accepts `projects/*/locations/*/secrets/*` paths. Watch trailing newlines in secret payloads.
8. Model roster in this project caps at `gemini-3-flash-preview` (no 3.5/3.6) — scaffold default changed accordingly.
9. gcloud SDK had to be upgraded (526→581) for `agent-gateways`/`agent-registry` groups; batch `services enable` max 20.
10. `mcp` PyPI 2.0.0 breaks ADK 2.7.1 — pinned `mcp>=1.16,<2`. Codelab TLS shim (pyopenssl) + `x-goog-user-project` header adopted in agent code.
11. **Model Armor gateway attachment is NOT a gateway field** (absent from v1/v1beta1/v1alpha1 AgentGateway schemas): it is an authz extension (`service: modelarmor.<region>.rep.googleapis.com`, metadata `model_armor_settings`) + authz policy with `policyProfile: CONTENT_AUTHZ`. The console toggle generates these.
12. **An unauthorized Model Armor callout fails CLOSED for ALL egress** — verified via three instrumented bind/unbind cycles: `('apm-gateway-modar-policy','DENIED')` + HTTP 500 on every request (even telemetry/session calls), template fully exonerated by direct sanitize tests in both enforcement modes. `failOpen: true` does not cover an authorization failure of the callout itself. Always re-test immediately after binding a CONTENT_AUTHZ policy; recovery = delete the policy (instant).
13. **Domain Restricted Sharing** (`iam.allowedPolicyMemberDomains`) blocks granting roles to gcp-sa-dep tenant service agents; the exception needs org-level rights (`orgpolicy.policies.create` denied to project owner). SDP templates require the `x-goog-user-project` header on DLP REST calls.

## Model Armor status (attach attempted via API — one org-policy blocker)

Everything except one IAM grant was completed via CLI/REST (no console needed):
- SDP inspect + de-identify templates created (DLP REST, quota-project header required).
- Attached to `apm-egress-template` as `advancedConfig` (redaction-capable), `enforcementType: INSPECT_ONLY`.
- Callout extension `apm-gateway-modar-ext` created (`service: modelarmor.us-east4.rep.googleapis.com`, metadata `model_armor_settings` JSON naming the template for request+response) — schema from the `agw-cuj-arun-ingress-modar` codelab.
- CONTENT_AUTHZ authz policy was bound to the gateway… and **rolled back after controlled experiments** (three bind/unbind cycles, gateway logs captured each time). Evidence:
  - Every request through the gateway logs `('apm-gateway-modar-policy', 'DENIED')` → HTTP 500, including non-AI traffic (session creation, telemetry metrics). IAP policy simultaneously logs ALLOWED.
  - **The template is exonerated**: direct `:sanitizeUserPrompt` calls work (PI/jailbreak MATCH at HIGH confidence on the injection string; all 5 filters EXECUTION_SUCCESS; findings in `modelarmor.googleapis.com/sanitize_operations` logs). The DENY reproduces identically with the template in `INSPECT_AND_BLOCK` (verdict-returning) mode — so template mode/shape is not the cause.
  - Remaining known-broken link: the Service Extensions service agent (`service-921170260575@gcp-sa-dep.iam.gserviceaccount.com`) lacks `roles/modelarmor.calloutUser` / `modelarmor.user` / `serviceusage.serviceUsageConsumer` — grants rejected by org policy **`constraints/iam.allowedPolicyMemberDomains`** (Domain Restricted Sharing). Conclusion: the callout cannot authenticate to Model Armor, CONTENT_AUTHZ denies everything, and `failOpen: true` does not rescue an unauthorized callout.
  - Note (WAI, not a bug): a template in `INSPECT_ONLY` mode returns empty sanitize responses by design — findings go to Cloud Logging with verdict ALLOW ("not blocked as the enforcement type is inspect only").

**To enable Model Armor screening (org admin, one-time):** grant a DRS exception for project `schwab-agent-poc` (or allow the SA), then:
```bash
for role in roles/modelarmor.calloutUser roles/modelarmor.user roles/serviceusage.serviceUsageConsumer; do
  gcloud projects add-iam-policy-binding schwab-agent-poc \
    --member="serviceAccount:service-921170260575@gcp-sa-dep.iam.gserviceaccount.com" --role="$role"; done
gcloud beta network-security authz-policies import apm-gateway-modar-policy \
  --source=infra/modar-authz-policy.yaml --location=us-east4   # re-test agent immediately after
```
⚠️ Re-bind during a quiet window and re-test at once — if the callout still can't authenticate, the gateway fails closed again (delete the policy to recover).

## Model Armor: NOW LIVE (updated 2026-08-18 23:07 UTC)

The earlier "org-admin blocker" was a misdiagnosis: DRS blocks the **tenant-project** dep SA shown on the gateway card (`service-921170260575@gcp-sa-dep`), but permits the **same-project** service agent the docs actually specify — `service-82648816720@gcp-sa-dep.iam.gserviceaccount.com`. With `roles/modelarmor.calloutUser` + `modelarmor.user` + `serviceusage.serviceUsageConsumer` granted to it (and `dlp.user`/`dlp.reader` to `service-82648816720@gcp-sa-modelarmor` for advanced SDP), the CONTENT_AUTHZ policy **`apm-gateway-modar-policy` is bound and verified**: happy path 200, `('apm-gateway-modar-policy','ALLOWED')` on every request, template in `INSPECT_ONLY`, advanced SDP redaction proven (`[EMAIL_ADDRESS]`/`[US_SOCIAL_SECURITY_NUMBER]`). Configs: `infra/modar-authz-ext.yaml` / `infra/modar-authz-policy.yaml`.

## Semantic governance policies: built, blocked at PSC (org policy)

Done: SGP engine ACTIVE (us-east4); policies `apm-sql-readonly` (SELECT-only, single-APM-ID WHERE, apm_assets-only, no SELECT *) and `apm-agent-purpose` (lookup-only, no exfil, never reveal secrets, row text is data) created against registry agent `agentregistry-…-8a62-a58a21034534` (note: `--agent` needs the FULL resource path); VPC `sgp-net` + subnets (10.11.12.0/24, proxy 10.11.13.0/24) + private zone `agentic.internal.` + `sgp-attachment`; engine `gatewayConfigs` PATCHed via REST (the gcloud `--gateway-config` flag 400s); `roles/compute.networkAdmin` + `roles/dns.admin` granted to `service-82648816720@gcp-sa-aiplatform` (it creates the PSC endpoint — first failure was `compute.addresses.createInternal`).

**Blocker (verified, genuine):** org policy **`constraints/compute.disablePrivateServiceConnectCreationForConsumers` = denyAll** rejects the PSC forwarding rule (`sgpe-psce-apm-agw`) the engine binding must create. Project-level override requires `orgpolicy.policies.create` (denied to project owner).

**To activate after the org-admin exception** (project-level `enforce: false` for `schwab-agent-poc`, or a tag-conditioned exception):
1. Re-PATCH the engine gatewayConfigs (idempotent; exact curl in the SGP section of the runbook) and wait for `gatewayConfigs.apm-agw.state: ACTIVE`; note the DNS record `us-east4.agentic.internal` it creates.
2. Add the gateway `networkConfig` (egress networkAttachment `sgp-attachment` + dnsPeering for `agentic.internal.` → `sgp-net`) via gateway re-import.
3. Import `infra/sgp-authz-ext.yaml` (already in DRY_RUN, `failOpen: false` per docs) + `infra/sgp-authz-policy.yaml` — **instrumented bind: test the agent immediately; rollback = delete the policy**.
4. Verify verdicts in `logName="projects/schwab-agent-poc/logs/semantic-governance-policy"` (fields: `verdict`, `evaluations[].rationale`), then flip DRY_RUN off by PATCHing the extension metadata.

## Remaining human actions

1. **Org admin (unblocks semantic policies):** project-level exception to `constraints/compute.disablePrivateServiceConnectCreationForConsumers` for `schwab-agent-poc` (set `enforce: false`, or a tag-conditioned exception). Then follow the 4 activation steps in the SGP section above. ~~Model Armor DRS exception~~ — no longer needed (resolved; see Model Armor section).
2. **Org admin (hardening, non-blocking):** IAM deny policy (destructive Cloud SQL perms) + Principal Access Boundary for the agent principal — needs org-level `iam.denyAdmin`.
3. **Cleanup before enforce:** remove the temporary `debug_env` / `debug_probe` / `debug_mcp` operations from `app/agent_engine_app.py` and redeploy.
4. **After ~1 week of audit logs:** Phase 10 enforce flip — Model Armor `INSPECT_ONLY` → `INSPECT_AND_BLOCK` (template PATCH); SGP DRY_RUN off (extension metadata PATCH); IAP audit → enforce; narrow `iap.egressor` from registry-wide to the MCP server. Re-run the validation checklist expecting hard blocks.

## How to query the agent

Console playground: https://console.cloud.google.com/vertex-ai/agents/agent-engines/locations/us-east4/agent-engines/4353476707760472064/playground?project=schwab-agent-poc

REST: `POST …/reasoningEngines/4353476707760472064:streamQuery` with `{"class_method":"stream_query","input":{"user_id":"...","message":"Look up APM001234"}}`.

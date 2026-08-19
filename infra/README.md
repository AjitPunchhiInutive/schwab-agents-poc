# Gateway & governance infrastructure configs

The exact configs applied to `schwab-agent-poc` (substitute project/region for a new site — full context in `../agent-gateway-setup-runbook.md`, phase refs below).

| File | What | Applied with | Runbook |
|---|---|---|---|
| `gateway-egress.yaml` | Agent Gateway (AGENT_TO_ANYWHERE, MCP, registry ref) | `gcloud network-services agent-gateways import` | Phase 4 |
| `iap-authz-ext.yaml` | IAP authz extension (`iamEnforcementMode: DRY_RUN`) | `gcloud beta service-extensions authz-extensions import` | Phase 7 |
| `iap-authz-policy.yaml` | REQUEST_AUTHZ policy binding IAP ext → gateway | `gcloud network-security authz-policies import` | Phase 7 |
| `modar-authz-ext.yaml` | Model Armor callout ext (`model_armor_settings`) | authz-extensions import | Phase 8.4 |
| `modar-authz-policy.yaml` | CONTENT_AUTHZ policy — **httpRules exclusions for `application/grpc` AND `:generateContent` paths are MANDATORY** (see runbook §8.4/§8.6) | authz-policies import | Phase 8.4 |
| `sgp-authz-ext.yaml` | Semantic-governance callout ext (DRY_RUN, private DNS host) | authz-extensions import | Phase 8b.3 — ⚠️ bind only after PSC org-policy exception |
| `sgp-authz-policy.yaml` | CONTENT_AUTHZ policy scoped to model-call paths for SGP | authz-policies import | Phase 8b.3 |
| `agents-iap-policy.json` | `roles/iap.egressor` for the agent principal (registry-wide) | `gcloud iap web set-iam-policy --resource-type=agent-registry --region=global` (fetch-merge-set!) | Phase 6.1 |
| `egressor-mcp.json` | Same, scoped to the Cloud SQL MCP server (`--mcp-server=ID`) | same | Phase 6.1 / 10 |
| `deny-agent-destructive.json` | IAM deny policy (destructive Cloud SQL perms) — **needs org-level `iam.denyAdmin`** | `gcloud iam policies create --kind=denypolicies` | Phase 6.4 |
| `drs-override.yaml` / `psc-override.yaml` | Org-policy overrides (DRS not needed in the end; PSC one IS the SGP blocker) — **org admin only** | `gcloud org-policies set-policy` | Appendix A.2 |

⚠️ The agent-principal JSONs embed the ENGINE ID inside the principal string — regenerate them if the engine is recreated.

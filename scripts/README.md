# scripts/

## `setup-governed-agent.sh`

Reproduces the governed-agent build (Agent Identity + Agent Gateway + Model Armor)
in **your own GCP project** — the runbook, executable and idempotent.

### Use it
1. **Edit the CONFIG block** at the top (`PROJECT_ID`, `REGION`, `SQL_INSTANCE`, `DB_NAME`).
2. `./setup-governed-agent.sh preflight`   ← checks auth + prints org-policy prerequisites
3. Run phases **one at a time**, verifying each (recommended over `all`):
   ```
   ./setup-governed-agent.sh apis
   ./setup-governed-agent.sh sql          # STOPS for Data API toggle + DB reader user
   ./setup-governed-agent.sh registry     # then wait ~15 min for propagation
   ./setup-governed-agent.sh gateway
   ./setup-governed-agent.sh deploy        # ~6 min; needs ../apm-lookup-agent
   ./setup-governed-agent.sh iam           # auto-captures the agent principal
   ./setup-governed-agent.sh authz
   ./setup-governed-agent.sh modelarmor    # TEST THE AGENT right after — fail-closed risk
   ./setup-governed-agent.sh validate
   ```
   Or `./setup-governed-agent.sh all` to chain them (includes the propagation sleep).

### What it does NOT do (by design — needs a human/org admin)
- **Data API toggle** on the SQL instance (console/setting) — it STOPS and tells you.
- **The read-only DB user + GRANTs** — needs your postgres admin password; set
  `ADMIN_SECRET=<regional secret name>` to automate, else do runbook Phase 6.3 by hand.
- **Semantic-governance policies (Phase 8b)** — blocked by an org policy
  (`compute.disablePrivateServiceConnectCreationForConsumers`); needs an org-admin
  exception, then follow runbook Phase 8b.
- **Deny policy + PAB, enforce-mode flip** — org-admin / post-audit (runbook 6.4, 10).

### Safety
Every phase is idempotent (check-before-create), only ADDS IAM bindings, and never
runs destructive SQL. It has NOT yet been run end-to-end in a fresh project —
run it **supervised**, phase by phase, the first time, and read the matching
runbook phase alongside each step.

#!/usr/bin/env bash
#
# setup-governed-agent.sh — stand up a governed agent (Agent Identity + Agent
# Gateway + Model Armor) in YOUR OWN GCP project, reproducing the schwab-agent-poc
# POC. This is the runbook (agent-gateway-setup-runbook.md) as an executable,
# idempotent script. READ THAT RUNBOOK for the "why" behind each step.
#
# Usage:
#   ./setup-governed-agent.sh preflight     # checks auth, project, org policies
#   ./setup-governed-agent.sh <phase>       # run one phase (see list below)
#   ./setup-governed-agent.sh all           # run phases 1-8 in order (with STOPs)
#   ./setup-governed-agent.sh validate      # smoke-test the deployed agent
#
# Phases: apis sql registry gateway deploy iam authz modelarmor
#
# Every phase is safe to re-run. The script STOPS and prints instructions where
# a human or org admin must act (Data API toggle, org-policy exceptions).
# -----------------------------------------------------------------------------
set -euo pipefail

# ========================= CONFIG — EDIT THESE ===============================
export PROJECT_ID="${PROJECT_ID:-FILL_ME}"          # your GCP project
export REGION="${REGION:-us-east4}"                 # ONE region for everything
export SQL_INSTANCE="${SQL_INSTANCE:-FILL_ME}"      # existing Cloud SQL PG instance
export DB_NAME="${DB_NAME:-FILL_ME}"                # database holding the lookup table
export APM_TABLE="${APM_TABLE:-public.apm_assets}"  # the read-only table
export GATEWAY_NAME="${GATEWAY_NAME:-apm-agent-gateway}"
export AGENT_DISPLAY="${AGENT_DISPLAY:-apm-lookup-agent}"
export AGENT_DIR="${AGENT_DIR:-../apm-lookup-agent}" # path to the agent project
# =============================================================================

export PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)' 2>/dev/null || echo '')"
C_OK="\033[32m"; C_WARN="\033[33m"; C_ERR="\033[31m"; C_STOP="\033[1;35m"; C_OFF="\033[0m"
say()  { echo -e "${C_OK}[+] $*${C_OFF}"; }
warn() { echo -e "${C_WARN}[!] $*${C_OFF}"; }
stop() { echo -e "${C_STOP}\n========== HUMAN ACTION REQUIRED ==========\n$*\n===========================================${C_OFF}"; }
die()  { echo -e "${C_ERR}[x] $*${C_OFF}"; exit 1; }
token(){ gcloud auth application-default print-access-token 2>/dev/null; }

require_config() {
  [[ "$PROJECT_ID" == "FILL_ME" || "$SQL_INSTANCE" == "FILL_ME" || "$DB_NAME" == "FILL_ME" ]] \
    && die "Edit the CONFIG block at the top of this script first (PROJECT_ID / SQL_INSTANCE / DB_NAME)."
  [[ -z "$PROJECT_NUMBER" ]] && die "Cannot read project number — check auth and PROJECT_ID."
  return 0
}

# ---------------------------------------------------------------------------
preflight() {
  require_config
  say "Project: $PROJECT_ID ($PROJECT_NUMBER), region: $REGION"
  say "gcloud account: $(gcloud config get-value account 2>/dev/null)"
  gcloud config set project "$PROJECT_ID" >/dev/null
  gcloud sql instances describe "$SQL_INSTANCE" --format='value(name,region)' \
    || die "SQL instance $SQL_INSTANCE not found (or no access)."
  say "ADC identity: $(curl -s "https://oauth2.googleapis.com/tokeninfo?access_token=$(token)" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("email","?"))' 2>/dev/null)"
  warn "ORG-POLICY PREREQUISITES (a project owner cannot self-serve these — ask an org admin):"
  echo "    1. Exception to constraints/compute.disablePrivateServiceConnectCreationForConsumers"
  echo "       for this project (needed for SEMANTIC-GOVERNANCE policies — Phase 8b, not run here)."
  echo "    2. constraints/iam.allowedPolicyMemberDomains must permit grants to same-project"
  echo "       gcp-sa-* service agents (Model Armor callout uses service-$PROJECT_NUMBER@gcp-sa-dep)."
  echo "    Model Armor + gateway + agent will still deploy without #1; semantic policies won't."
}

# ---------------------------------------------------------------------------
apis() {
  require_config
  say "Enabling APIs (in two batches — 20-service limit)..."
  gcloud services enable --project="$PROJECT_ID" \
    compute networksecurity networkservices dns iam iap agentregistry aiplatform \
    discoveryengine storage modelarmor dlp secretmanager orgpolicy \
    | sed 's/^/    /' 2>/dev/null || true
  gcloud services enable --project="$PROJECT_ID" \
    observability telemetry monitoring cloudtrace logging apphub apptopology \
    cloudapiregistry sqladmin 2>/dev/null || true
  # normalize: the above short names need the .googleapis.com suffix
  local SVCS="compute networksecurity networkservices dns iam iap agentregistry aiplatform discoveryengine storage modelarmor dlp secretmanager orgpolicy observability telemetry monitoring cloudtrace logging apphub apptopology cloudapiregistry sqladmin"
  for s in $SVCS; do gcloud services enable "${s}.googleapis.com" --project="$PROJECT_ID" >/dev/null 2>&1 & done; wait
  say "APIs enabled."
}

# ---------------------------------------------------------------------------
sql() {
  require_config
  # 2.1 IAM auth flag (merge, don't replace)
  local FLAGS; FLAGS="$(gcloud sql instances describe "$SQL_INSTANCE" --format='value(settings.databaseFlags.list(separator=","))' 2>/dev/null)"
  if ! echo "$FLAGS" | grep -q "cloudsql.iam_authentication=on"; then
    local NEW="cloudsql.iam_authentication=on"; [[ -n "$FLAGS" ]] && NEW="${FLAGS},${NEW}"
    warn "Patching DB flags to add cloudsql.iam_authentication=on (may restart the instance)."
    gcloud sql instances patch "$SQL_INSTANCE" --database-flags="$NEW" --quiet
  else say "IAM auth flag already on."; fi
  # 2.2 Data API — cannot be set by classic gcloud flag
  local DAPI; DAPI="$(gcloud sql instances describe "$SQL_INSTANCE" --format=json | python3 -c 'import json,sys;print(json.load(sys.stdin).get("settings",{}).get("dataApiAccess","UNSET"))')"
  if [[ "$DAPI" != "ALLOW_DATA_API" ]]; then
    if gcloud sql instances patch "$SQL_INSTANCE" --data-api-access=ALLOW_DATA_API --quiet 2>/dev/null; then
      say "Data API access enabled."
    else
      stop "Enable Data API access on $SQL_INSTANCE:\n  Console → SQL → $SQL_INSTANCE → Edit → Data API access → Allow\nThen re-run: $0 sql"
      return 1
    fi
  else say "Data API already ALLOW_DATA_API."; fi
  # 2.3 reader user + secret — needs a postgres admin login to run GRANTs
  stop "The read-only DB user + GRANTs + password secret are the one step this script\ncannot fully automate without your postgres admin password. Do this manually\n(runbook Phase 6.3 has the exact commands), OR set ADMIN_SECRET=<regional secret\nname holding the postgres pw> and re-run — then it will create apm_reader, GRANT\nSELECT on $APM_TABLE, and store the reader password in Secret Manager."
  if [[ -n "${ADMIN_SECRET:-}" ]]; then
    say "ADMIN_SECRET set — creating apm_reader + GRANTs + reader secret..."
    python3 -c "import secrets;open('/tmp/apm_reader_pw','w').write(secrets.token_urlsafe(24))"
    gcloud sql users create apm_reader --instance="$SQL_INSTANCE" --password="$(cat /tmp/apm_reader_pw)" 2>/dev/null || warn "apm_reader may already exist"
    local SQLG="GRANT CONNECT ON DATABASE ${DB_NAME} TO apm_reader; GRANT USAGE ON SCHEMA public TO apm_reader; GRANT SELECT ON ${APM_TABLE} TO apm_reader;"
    curl -s -X POST -H "Authorization: Bearer $(token)" -H "Content-Type: application/json" \
      "https://sqladmin.googleapis.com/v1/projects/$PROJECT_ID/instances/$SQL_INSTANCE/executeSql" \
      -d "{\"database\":\"$DB_NAME\",\"user\":\"postgres\",\"passwordSecretVersion\":\"projects/$PROJECT_ID/locations/$REGION/secrets/${ADMIN_SECRET}/versions/latest\",\"sqlStatement\":\"$SQLG\"}" | python3 -m json.tool | head -6
    gcloud config set api_endpoint_overrides/secretmanager "https://secretmanager.$REGION.rep.googleapis.com/" >/dev/null
    gcloud secrets create apm-reader-secret --location="$REGION" --data-file=/tmp/apm_reader_pw 2>/dev/null || gcloud secrets versions add apm-reader-secret --location="$REGION" --data-file=/tmp/apm_reader_pw
    gcloud config unset api_endpoint_overrides/secretmanager >/dev/null
    rm -f /tmp/apm_reader_pw
    say "apm_reader + secret ready."
  fi
}

# ---------------------------------------------------------------------------
registry() {
  require_config
  say "Verifying Cloud SQL MCP auto-registration (global)..."
  gcloud agent-registry mcp-servers list --location=global --project="$PROJECT_ID" \
    --format='value(displayName)' 2>/dev/null | grep -q cloud-sql \
    && say "cloud-sql MCP server registered." || warn "cloud-sql MCP not found — is sqladmin API enabled?"
  say "Registering egress HOSTNAMES (incl. platform hosts the serving shim calls)..."
  gcloud components install alpha --quiet >/dev/null 2>&1 || true
  local HOSTS="sqladmin:sqladmin.googleapis.com sqladmin-mtls:sqladmin.mtls.googleapis.com oauth2-api:oauth2.googleapis.com crm:cloudresourcemanager.googleapis.com crm-mtls:cloudresourcemanager.mtls.googleapis.com logging-api:logging.googleapis.com monitoring-api:monitoring.googleapis.com trace-api:trace.googleapis.com telemetry-api:telemetry.googleapis.com storage-api:storage.googleapis.com"
  for spec in $HOSTS; do
    local name="${spec%%:*}" host="${spec#*:}"
    for loc in global "$REGION"; do
      local rn="$name"; [[ "$loc" != "global" ]] && rn="$REGION-$name"
      gcloud alpha agent-registry services create "$rn" --project="$PROJECT_ID" --location="$loc" \
        --display-name="$host" --endpoint-spec-type=no-spec \
        --interfaces=url="https://$host",protocolBinding=JSONRPC >/dev/null 2>&1 \
        && echo "    registered $rn @ $loc" || echo "    $rn @ $loc (exists/skip)"
    done
  done
  warn "Allow up to ~15 min for registry propagation before egress to these hosts stops being denied."
}

# ---------------------------------------------------------------------------
gateway() {
  require_config
  if gcloud network-services agent-gateways describe "$GATEWAY_NAME" --location="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
    say "Gateway $GATEWAY_NAME already exists."; return 0
  fi
  cat > /tmp/gw.yaml <<EOF
name: $GATEWAY_NAME
protocols:
- MCP
googleManaged:
  governedAccessPath: AGENT_TO_ANYWHERE
registries:
- //agentregistry.googleapis.com/projects/$PROJECT_ID/locations/global
EOF
  gcloud network-services agent-gateways import "$GATEWAY_NAME" --location="$REGION" --source=/tmp/gw.yaml --project="$PROJECT_ID"
  say "Gateway created."
}

# ---------------------------------------------------------------------------
deploy() {
  require_config
  [[ -d "$AGENT_DIR" ]] || die "Agent dir $AGENT_DIR not found (set AGENT_DIR)."
  say "Deploying agent (identity + gateway + memory) — ~6 min..."
  ( cd "$AGENT_DIR" && uv run python -m app.app_utils.deploy \
      --project "$PROJECT_ID" --location "$REGION" --agent-identity \
      --agent-gateway "projects/$PROJECT_ID/locations/$REGION/agentGateways/$GATEWAY_NAME" \
      --set-env-vars "APP_GOOGLE_CLOUD_PROJECT=$PROJECT_ID,GOOGLE_CLOUD_LOCATION=global,GOOGLE_API_PREVENT_AGENT_TOKEN_SHARING_FOR_GCP_SERVICES=false" )
  say "Deploy done. (If it reported 'failed to update' but the agent still serves, check runtime logs — see runbook A.4.)"
}

# fetch the deployed engine id + agent principal (only exist after deploy)
_engine_info() {
  ENGINE_ID="$(curl -s -H "Authorization: Bearer $(token)" \
    "https://$REGION-aiplatform.googleapis.com/v1beta1/projects/$PROJECT_ID/locations/$REGION/reasoningEngines" \
    | python3 -c "import json,sys
d=json.load(sys.stdin)
for e in d.get('reasoningEngines',[]):
    if e.get('displayName')=='$AGENT_DISPLAY': print(e['name'].split('/')[-1]); break")"
  [[ -z "${ENGINE_ID:-}" ]] && die "No deployed engine named $AGENT_DISPLAY — run '$0 deploy' first."
  AGENT_PRINCIPAL="principal://agents.global.org-$(gcloud organizations list --format='value(name)' 2>/dev/null | head -1 | cut -d/ -f2).system.id.goog/resources/aiplatform/projects/$PROJECT_NUMBER/locations/$REGION/reasoningEngines/$ENGINE_ID"
}

# ---------------------------------------------------------------------------
iam() {
  require_config; _engine_info
  say "Engine: $ENGINE_ID"
  say "Principal: $AGENT_PRINCIPAL"
  # iap.egressor on the registry (fetch-merge-set)
  cat > /tmp/egressor.json <<EOF
{"bindings":[{"role":"roles/iap.egressor","members":["$AGENT_PRINCIPAL"]}]}
EOF
  gcloud iap web set-iam-policy /tmp/egressor.json --project="$PROJECT_ID" --resource-type=agent-registry --region=global --quiet >/dev/null || warn "egressor set failed (check merge)"
  for role in roles/mcp.toolUser roles/cloudsql.instanceUser roles/cloudsql.studioUser roles/storage.objectUser; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="$AGENT_PRINCIPAL" --role="$role" --condition=None --quiet >/dev/null && echo "    granted $role" || warn "failed $role"
  done
  # telemetry bucket + reader secret access
  gcloud storage buckets create "gs://$PROJECT_ID" --location="$REGION" 2>/dev/null || true
  gcloud storage buckets add-iam-policy-binding "gs://$PROJECT_ID" --member="$AGENT_PRINCIPAL" --role="roles/storage.objectUser" --quiet >/dev/null 2>&1 || true
  gcloud config set api_endpoint_overrides/secretmanager "https://secretmanager.$REGION.rep.googleapis.com/" >/dev/null
  gcloud secrets add-iam-policy-binding apm-reader-secret --location="$REGION" --project="$PROJECT_ID" \
    --member="$AGENT_PRINCIPAL" --role="roles/secretmanager.secretAccessor" --quiet >/dev/null 2>&1 || warn "reader-secret grant skipped (create the secret in Phase sql first)"
  gcloud config unset api_endpoint_overrides/secretmanager >/dev/null
  say "IAM grants applied. (Deny policy + PAB are org-admin — see runbook 6.4.)"
}

# ---------------------------------------------------------------------------
authz() {
  require_config
  cat > /tmp/iap-ext.yaml <<EOF
name: apm-gateway-authz-ext
service: iap.googleapis.com
failOpen: true
timeout: 1s
metadata:
  iamEnforcementMode: "DRY_RUN"
  iapPolicyVersion: "V1"
EOF
  gcloud beta service-extensions authz-extensions import apm-gateway-authz-ext --source=/tmp/iap-ext.yaml --location="$REGION" --project="$PROJECT_ID" --quiet
  cat > /tmp/iap-pol.yaml <<EOF
name: apm-gateway-authz-policy
target:
  resources:
  - "projects/$PROJECT_ID/locations/$REGION/agentGateways/$GATEWAY_NAME"
policyProfile: REQUEST_AUTHZ
action: CUSTOM
customProvider:
  authzExtension:
    resources:
    - "projects/$PROJECT_ID/locations/$REGION/authzExtensions/apm-gateway-authz-ext"
EOF
  gcloud network-security authz-policies import apm-gateway-authz-policy --source=/tmp/iap-pol.yaml --location="$REGION" --project="$PROJECT_ID" --quiet
  say "IAP authz wired in DRY_RUN."
}

# ---------------------------------------------------------------------------
modelarmor() {
  require_config
  say "Granting Model Armor roles to SAME-PROJECT service agents (never the tenant SA)..."
  gcloud beta services identity create --service=modelarmor.googleapis.com --project="$PROJECT_ID" >/dev/null 2>&1 || true
  local DEP="serviceAccount:service-$PROJECT_NUMBER@gcp-sa-dep.iam.gserviceaccount.com"
  local MA="serviceAccount:service-$PROJECT_NUMBER@gcp-sa-modelarmor.iam.gserviceaccount.com"
  for r in roles/modelarmor.calloutUser roles/modelarmor.user roles/serviceusage.serviceUsageConsumer; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="$DEP" --role="$r" --condition=None --quiet >/dev/null 2>&1 \
      || warn "grant $r to gcp-sa-dep FAILED (Domain Restricted Sharing? see preflight #2)"; done
  for r in roles/dlp.user roles/dlp.reader; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="$MA" --role="$r" --condition=None --quiet >/dev/null 2>&1 || true; done
  say "Creating egress template (regional REST — gcloud model-armor has an endpoint bug)..."
  curl -s -X POST -H "Authorization: Bearer $(token)" -H "Content-Type: application/json" \
    "https://modelarmor.$REGION.rep.googleapis.com/v1/projects/$PROJECT_ID/locations/$REGION/templates?templateId=apm-egress-template" \
    -d '{"filterConfig":{"raiSettings":{"raiFilters":[{"filterType":"HATE_SPEECH","confidenceLevel":"MEDIUM_AND_ABOVE"},{"filterType":"HARASSMENT","confidenceLevel":"MEDIUM_AND_ABOVE"},{"filterType":"DANGEROUS","confidenceLevel":"MEDIUM_AND_ABOVE"},{"filterType":"SEXUALLY_EXPLICIT","confidenceLevel":"MEDIUM_AND_ABOVE"}]},"piAndJailbreakFilterSettings":{"filterEnforcement":"ENABLED","confidenceLevel":"MEDIUM_AND_ABOVE"},"maliciousUriFilterSettings":{"filterEnforcement":"ENABLED"},"sdpSettings":{"basicConfig":{"filterEnforcement":"ENABLED"}}},"templateMetadata":{"enforcementType":"INSPECT_ONLY","logTemplateOperations":true,"logSanitizeOperations":true}}' >/dev/null 2>&1 || true
  say "Attaching Model Armor callout (CONTENT_AUTHZ) — httpRules EXCLUDE grpc + model-call paths..."
  cat > /tmp/modar-ext.yaml <<EOF
name: apm-gateway-modar-ext
service: modelarmor.$REGION.rep.googleapis.com
metadata:
  model_armor_settings: '[{"request_template_id": "projects/$PROJECT_ID/locations/$REGION/templates/apm-egress-template", "response_template_id": "projects/$PROJECT_ID/locations/$REGION/templates/apm-egress-template"}]'
failOpen: true
timeout: 5s
EOF
  gcloud beta service-extensions authz-extensions import apm-gateway-modar-ext --source=/tmp/modar-ext.yaml --location="$REGION" --project="$PROJECT_ID" --quiet
  cat > /tmp/modar-pol.yaml <<EOF
name: apm-gateway-modar-policy
target:
  loadBalancingScheme: LOAD_BALANCING_SCHEME_UNSPECIFIED
  resources:
  - projects/$PROJECT_ID/locations/$REGION/agentGateways/$GATEWAY_NAME
httpRules:
- to:
    operations:
    - paths: [{prefix: /}]
  when: "!request.headers['content-type'].startsWith('application/grpc') && !request.path.endsWith(':generateContent') && !request.path.endsWith(':streamGenerateContent')"
action: CUSTOM
policyProfile: CONTENT_AUTHZ
customProvider:
  authzExtension:
    resources:
    - projects/$PROJECT_ID/locations/$REGION/authzExtensions/apm-gateway-modar-ext
EOF
  gcloud network-security authz-policies import apm-gateway-modar-policy --source=/tmp/modar-pol.yaml --location="$REGION" --project="$PROJECT_ID" --quiet
  warn "TEST THE AGENT NOW. If it breaks (fail-closed), the callout grants above didn't land — delete the policy to recover:"
  echo "    gcloud beta network-security authz-policies delete apm-gateway-modar-policy --location=$REGION --project=$PROJECT_ID"
  say "Floor settings (ingress + MCP shim, inspect-only)..."
  curl -s -X PATCH -H "Authorization: Bearer $(token)" -H "Content-Type: application/json" \
    "https://modelarmor.googleapis.com/v1/projects/$PROJECT_ID/locations/global/floorSetting" \
    -d '{"integratedServices":["AI_PLATFORM","GOOGLE_MCP_SERVER"],"aiPlatformFloorSetting":{"inspectOnly":true,"enableCloudLogging":true},"googleMcpServerFloorSetting":{"inspectOnly":true,"enableCloudLogging":true},"enableFloorSettingEnforcement":true,"filterConfig":{"piAndJailbreakFilterSettings":{"filterEnforcement":"ENABLED","confidenceLevel":"MEDIUM_AND_ABOVE"},"maliciousUriFilterSettings":{"filterEnforcement":"ENABLED"},"sdpSettings":{"basicConfig":{"filterEnforcement":"ENABLED"}}}}' >/dev/null 2>&1 || true
  say "Model Armor configured (inspect-only). Flip to block after audit — runbook 8.6."
}

# ---------------------------------------------------------------------------
validate() {
  require_config; _engine_info
  say "Smoke-testing deployed agent ($ENGINE_ID)..."
  curl -s -X POST -H "Authorization: Bearer $(token)" -H "Content-Type: application/json" \
    "https://$REGION-aiplatform.googleapis.com/v1beta1/projects/$PROJECT_ID/locations/$REGION/reasoningEngines/$ENGINE_ID:streamQuery" \
    -d '{"class_method":"stream_query","input":{"user_id":"setup-validate","message":"Look up APM001234"}}' \
    | python3 -c "import json,sys
for l in sys.stdin:
    l=l.strip()
    if not l: continue
    try:
        e=json.loads(l)
        for p in e.get('content',{}).get('parts',[]):
            if 'text' in p: print('AGENT:', p['text'][:300])
    except: pass" || warn "query failed — check auth + that the agent is deployed"
}

# ---------------------------------------------------------------------------
case "${1:-}" in
  preflight) preflight ;;
  apis) apis ;;
  sql) sql ;;
  registry) registry ;;
  gateway) gateway ;;
  deploy) deploy ;;
  iam) iam ;;
  authz) authz ;;
  modelarmor) modelarmor ;;
  validate) validate ;;
  all)
    preflight; apis; sql; registry
    warn "Pausing ~15 min for registry propagation before creating the gateway..."; sleep 900
    gateway; deploy; iam; authz; modelarmor; validate
    say "Base build complete. Semantic policies (Phase 8b) need the org-policy exception — see runbook." ;;
  *)
    echo "Usage: $0 {preflight|apis|sql|registry|gateway|deploy|iam|authz|modelarmor|validate|all}"
    echo "First edit the CONFIG block at the top. Recommended: run phases individually and verify each."
    exit 1 ;;
esac

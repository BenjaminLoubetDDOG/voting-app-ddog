#!/usr/bin/env bash
set -euo pipefail

# ====== Required ENV (fill before running) ======
# GHCR (private)
: "${IMAGE_OWNER:?Set IMAGE_OWNER, e.g. benjaminloubetddog}"
# Using :latest tags for all images
: "${GHCR_PAT:?Set GHCR_PAT (GitHub PAT with read:packages)}"

# Datadog
: "${DD_API_KEY:?Set DD_API_KEY}"
: "${DD_SITE:=datadoghq.com}"     # us site (you provided .com). ex: datadoghq.eu for EU
: "${DD_ENV:=demo}"

# Scope
: "${SSI_SCOPE:=opt-in}"          # opt-in or all

# App namespace
: "${NS_APP:=voting-app}"

# Paths/ports
## Hardcoded manifests path
K8S_DIR="/Users/benjamin.loubet/voting-app-ddog/k8s-specifications"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
: "${VOTE_LOCAL_PORT:=8080}"
: "${RESULT_LOCAL_PORT:=8081}"
: "${PF_PIDFILE:=.portforward.pids}"

# Derived
IMAGE_REG="ghcr.io/${IMAGE_OWNER}"

# --- Synthetics Private Location (PL) settings ---
: "${PL_NS:=synthetics}"
: "${PL_RELEASE:=dd-synth-pl}"
: "${PL_CONFIG_FILE:=}"      # ABSOLUTE path to your PL JSON
: "${PL_LOG_LEVEL:=info}"    # or 'debug'


# ====== Helpers ======
info(){ echo "👉 $*"; }
ok(){ echo "✅ $*"; }
warn(){ echo "⚠️  $*"; }
die(){ echo "❌ $*"; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing '$1'"; }
k(){ kubectl "$@"; }
kns(){ kubectl -n "$NS_APP" "$@"; }
# put this near the top, with other helpers
get_tag_for() {
  echo "master"
}

preflight(){
  need kubectl; need helm; need docker
  # Older kubectl may not support --short; use cluster-info as the connectivity test
  if ! kubectl cluster-info >/dev/null 2>&1; then
    die "kubectl cannot reach the API server (is minikube running? correct context set?)"
  fi
  ok "kubectl connected to cluster."
}

pl_install() {
  preflight
  [ -n "${PL_CONFIG_FILE}" ] || die "Set PL_CONFIG_FILE to your private location JSON file (absolute path)."
  [ -f "${PL_CONFIG_FILE}" ] || die "PL_CONFIG_FILE not found at: ${PL_CONFIG_FILE}"

  info "Creating namespace ${PL_NS}…"
  kubectl create ns "${PL_NS}" --dry-run=client -o yaml | kubectl apply -f -

  info "Adding Datadog Helm repo (if needed)…"
  helm repo add datadog https://helm.datadoghq.com >/dev/null 2>&1 || true
  helm repo update >/dev/null

  info "Installing/Upgrading Synthetics Private Location via Helm…"
    # zsh-safe Helm upgrade (quote every key that has [index])
  helm upgrade --install dd-synth-pl datadog/synthetics-private-location \
    -n synthetics --create-namespace \
    --set-file "configFile=$PL_CONFIG_FILE" \
    --set "extraEnv[0].name=DD_LOG_LEVEL" \
    --set "extraEnv[0].value=${PL_LOG_LEVEL}" \
    --set "dnsPolicy=ClusterFirst" \
    --set "dnsConfig.searches[0]=svc.cluster.local" \
    --set "dnsConfig.searches[1]=cluster.local" \
    --set "image.repository=public.ecr.aws/datadog/synthetics-private-location-worker" \
    --set "image.tag=1.58.0" \
    --set "image.pullPolicy=Always"
v
    # zsh-safe Helm upgrade (quote every key that has [index])
helm upgrade --install dd-synth-pl datadog/synthetics-private-location \
  -n synthetics --create-namespace \
  --set-file "configFile=$PL_CONFIG_FILE" \
  --set "extraEnv[0].name=DD_LOG_LEVEL" \
  --set "extraEnv[0].value=${PL_LOG_LEVEL}" \
  --set "dnsPolicy=ClusterFirst" \
  --set "dnsConfig.searches[0]=svc.cluster.local" \
  --set "dnsConfig.searches[1]=cluster.local" \
  --set "image.repository=public.ecr.aws/datadog/synthetics-private-location-worker" \
  --set "image.tag=1.58.0" \
  --set "image.pullPolicy=Always"

  # Robust wait: use the chart's stable label (works regardless of release name)
  info "Waiting for Private Location worker to be Ready…"
  kubectl -n "${PL_NS}" wait --for=condition=Available deploy \
    -l app.kubernetes.io/name=synthetics-private-location-worker \
    --timeout=300s || true

  kubectl -n "${PL_NS}" get pods -o wide
  ok "Private Location deployed in ns/${PL_NS} (release: ${PL_RELEASE})."
}

pl_uninstall() {
  info "Uninstalling Synthetics Private Location…"
  helm -n "${PL_NS}" uninstall "${PL_RELEASE}" || true
  kubectl delete ns "${PL_NS}" --ignore-not-found
  ok "Private Location removed."
}

write_dd_values(){
  cat > "${SCRIPT_DIR}/dd-values.yaml" <<YAML
env:
- name: STATSD_HOST
  value: datadog-dogstatsd.datadog.svc.cluster.local
- name: STATSD_PORT
  value: "8125"
datadog:
  site: ${DD_SITE}
  apiKeyExistingSecret: datadog-secret

    # --- Core ---
  clusterName: minikube-demo
  kubelet:
    tlsVerify: false
  apm:
    instrumentation:
      enabled: true
      targets:
        - name: "default-target"
          ddTraceVersions:
            java: "1"
            python: "3"
            js: "5"
            php: "1"
            dotnet: "3"
  logs:
    enabled: true
    containerCollectAll: true
  serviceMonitoring:
    enabled: true
  networkMonitoring:
    enabled: true
  processAgent:
    processCollection: true
  dogstatsd:
    originDetection: true
    tagCardinality: orchestrator
agents:
  containers:
    agent:
      # Explicitly force logs-agent to tail all container logs
      extraConfd:
        logs.yaml: |-
          logs:
            - type: docker
              service: autodiscovered
              source: docker
              container_collect_all: true
YAML
}

# Old version
write_dd_values_old(){
  cat > "${SCRIPT_DIR}/dd-values.yaml" <<YAML
datadog:
  site: ${DD_SITE}
  apiKeyExistingSecret: datadog-secret

    # --- Core ---
  clusterName: minikube-demo

  # Kubelet on Minikube often uses a self-signed cert
  kubelet:
    tlsVerify: false

  # --- Logs / Metrics ---
  logs:
    enabled: true

  # --- APM / Tracing ---
  # 'apm.enabled' is DEPRECATED. Use 'portEnabled' (TCP 8126) and 'socketEnabled' (UDS) instead.
  apm:
    portEnabled: true        # expose TCP 8126 for tracers that use host/service access
    socketEnabled: true      # keep UDS enabled (default true)
    instrumentation:
      enabled: true          # Single-Step Instrumentation (SSI)
$( if [ "${SSI_SCOPE}" = "opt-in" ]; then cat <<'EOT'
      targets:
        - name: apm-instrumented
          podSelector:
            matchLabels:
              datadoghq.com/apm-instrumentation: "enabled"
EOT
fi
)

  # --- Process / Containers / KSM / Prometheus ---
  processAgent:
    enabled: true
    processCollection: true

  logCollection:
    enabled: true
    containerCollectAll: true

  orchestratorExplorer:
    enabled: true

  kubeStateMetricsEnabled: true

  prometheusScrape:
    enabled: true

  # --- Network / Security / Profiler / OTLP ---
  networkMonitoring:
    enabled: true

  securityAgent:
    runtime:
      enabled: true
    compliance:
      enabled: true

  profiler:
    enabled: true

  otlp:
    enabled: true

# Cluster Agent defaults are fine for Minikube. For production HA, set:
# clusterAgent:
#   replicas: 2
#   createPodDisruptionBudget: true
YAML
}


install_agent(){
  preflight
  info "Preparing Datadog namespace + secret…"
  k create ns datadog --dry-run=client -o yaml | k apply -f -
  k -n datadog delete secret datadog-secret --ignore-not-found >/dev/null
  # Store API key in a secret
  k -n datadog create secret generic datadog-secret --from-literal api-key="${DD_API_KEY}" >/dev/null

  info "Helm repo setup…"
  helm repo add datadog https://helm.datadoghq.com >/dev/null 2>&1 || true
  helm repo update >/dev/null

  info "Writing dd-values.yaml…"
  write_dd_values

  info "Installing/Upgrading Datadog Agent (SSI: ${SSI_SCOPE})…"
  helm upgrade --install datadog-agent datadog/datadog -n datadog -f "${SCRIPT_DIR}/dd-values.yaml"


  info "Waiting for Agent DaemonSet to be ready…"
  k -n datadog rollout status ds/datadog-agent --timeout=300s || true
  k -n datadog get pods -o wide
  ok "Datadog Agent installed/updated."
}

setup_pull_secret(){
  info "Creating/attaching GHCR imagePullSecret in ${NS_APP}…"
  k create ns "${NS_APP}" --dry-run=client -o yaml | k apply -f -
  k -n "${NS_APP}" delete secret ghcr-creds --ignore-not-found >/dev/null
  k -n "${NS_APP}" create secret docker-registry ghcr-creds \
    --docker-server=ghcr.io \
    --docker-username="${IMAGE_OWNER}" \
    --docker-password="${GHCR_PAT}" >/dev/null

  # Attach to default SA (so all pods can pull private images)
  k -n "${NS_APP}" patch serviceaccount default \
    -p '{"imagePullSecrets":[{"name":"ghcr-creds"}]}' >/dev/null || true
  ok "imagePullSecret ready."
}

deploy_app(){
  preflight
  [ -d "$K8S_DIR" ] || die "K8S_DIR '$K8S_DIR' not found"
  info "Applying app manifests from $K8S_DIR"
  # Apply only *.yaml from K8S_DIR, excluding any dd-values.yaml by accident
  find "${K8S_DIR}" -type f -name '*.yaml' ! -name 'dd-values.yaml' -print0 \
  | xargs -0 -I{} kubectl apply -n "${NS_APP}" -f {}

  # Point to your images
  info "Setting images to GHCR…"
  kns set image deploy/vote   vote=${IMAGE_REG}/voting-app-vote:master || true
  kns set image deploy/result result=${IMAGE_REG}/voting-app-result:master || true
  kns set image deploy/worker worker=${IMAGE_REG}/voting-app-worker:master || true

  # SSI opt-in + Unified Service Tagging
  info "Labeling namespace and deployments for SSI + UST…"
  [ "${SSI_SCOPE}" = "opt-in" ] && k label ns "${NS_APP}" datadoghq.com/apm-instrumentation=enabled --overwrite >/dev/null || true

  for d in vote result worker; do
    if kns get deploy "$d" >/dev/null 2>&1; then
      ver="$(get_tag_for "$d")"
      kns patch deploy "$d" --type merge -p "{
        \"metadata\": {\"labels\": {
          \"datadoghq.com/apm-instrumentation\": \"enabled\",
          \"tags.datadoghq.com/env\": \"${DD_ENV}\",
          \"tags.datadoghq.com/service\": \"${d}\",
          \"tags.datadoghq.com/version\": \"${ver}\"
        }},
        \"spec\": {\"template\": {\"metadata\": {\"labels\": {
          \"datadoghq.com/apm-instrumentation\": \"enabled\",
          \"tags.datadoghq.com/env\": \"${DD_ENV}\",
          \"tags.datadoghq.com/service\": \"${d}\",
          \"tags.datadoghq.com/version\": \"${ver}\"
        }}}}
      }" >/dev/null
    fi
  done

  info "Rolling out (restart to trigger SSI injection)…"
  kns rollout restart deploy/vote || true
  kns rollout restart deploy/result || true
  kns rollout restart deploy/worker || true

  info "Waiting for readiness…"
  kns rollout status deploy/vote --timeout=240s || true
  kns rollout status deploy/result --timeout=240s || true
  kns rollout status deploy/worker --timeout=240s || true
  ok "App deployed."
}

verify(){
  echo "----- Datadog pods -----"
  k -n datadog get pods -o wide || true
  echo "----- App pods (look for dd init containers injected) -----"
  kns get pods -o jsonpath='{range .items[*]}{.metadata.name}{"  init:"}{.spec.initContainers[*].name}{"  ctr:"}{.spec.containers[*].name}{"\n"}{end}' || true
  echo
  kns get svc
}

start_pf(){
  [ -f "$PF_PIDFILE" ] && { warn "Port-forwards already running"; return; }
  
  # Check if local ports are available
  if lsof -ti:$VOTE_LOCAL_PORT >/dev/null 2>&1; then
    die "Local port $VOTE_LOCAL_PORT is already in use. Kill the process or choose a different port."
  fi
  if lsof -ti:$RESULT_LOCAL_PORT >/dev/null 2>&1; then
    die "Local port $RESULT_LOCAL_PORT is already in use. Kill the process or choose a different port."
  fi
  
  # Wait for services to have endpoints (be ready)
  info "Checking service readiness..."
  for svc in vote result; do
    attempt=1
    while [ $attempt -le 30 ]; do
      if kns get endpoints "$svc" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | grep -q .; then
        break
      fi
      if [ $attempt -eq 30 ]; then
        die "Service '$svc' not ready after 60 seconds"
      fi
      echo -n "."
      sleep 2
      attempt=$((attempt + 1))
    done
  done
  
  # Get service ports with better error handling
  VOTE_PORT="$(kns get svc vote -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)" || VOTE_PORT=80
  RESULT_PORT="$(kns get svc result -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)" || RESULT_PORT=80
  
  info "Starting port-forwards..."
  
  # Start port-forwards with better error detection
  > "$PF_PIDFILE"  # Create empty PID file
  
  # Vote service
  kns port-forward svc/vote "${VOTE_LOCAL_PORT}:${VOTE_PORT}" >/dev/null 2>&1 &
  vote_pid=$!
  echo "$vote_pid" >> "$PF_PIDFILE"
  
  # Result service  
  kns port-forward svc/result "${RESULT_LOCAL_PORT}:${RESULT_PORT}" >/dev/null 2>&1 &
  result_pid=$!
  echo "$result_pid" >> "$PF_PIDFILE"
  
  # Wait longer for establishment
  sleep 5
  
  # Verify port-forwards are actually working
  vote_ok=false
  result_ok=false
  
  for i in 1 2 3; do
    nc -z localhost "$VOTE_LOCAL_PORT" >/dev/null 2>&1 && vote_ok=true && break
    sleep 1
  done
  
  for i in 1 2 3; do
    nc -z localhost "$RESULT_LOCAL_PORT" >/dev/null 2>&1 && result_ok=true && break
    sleep 1
  done
  
  # Report status
  ok "Port-forward status:"
  if [ "$vote_ok" = true ]; then
    echo "• Vote   → http://localhost:${VOTE_LOCAL_PORT} ✅"
  else
    echo "• Vote   → http://localhost:${VOTE_LOCAL_PORT} ❌ (not responding)"
  fi
  
  if [ "$result_ok" = true ]; then
    echo "• Result → http://localhost:${RESULT_LOCAL_PORT} ✅"
  else
    echo "• Result → http://localhost:${RESULT_LOCAL_PORT} ❌ (not responding)"
  fi
  
  if [ "$vote_ok" = false ] || [ "$result_ok" = false ]; then
    warn "Some port-forwards may still be starting. Wait a moment and try accessing the URLs."
  fi
}

stop_pf(){
  [ -f "$PF_PIDFILE" ] || { warn "No port-forwards running"; return; }
  
  local pids_killed=0
  while read -r pid; do
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      if kill "$pid" 2>/dev/null; then
        pids_killed=$((pids_killed + 1))
        # Wait a moment for graceful shutdown
        sleep 0.5
        # Force kill if still running
        kill -9 "$pid" 2>/dev/null || true
      fi
    fi
  done < "$PF_PIDFILE"
  
  rm -f "$PF_PIDFILE"
  
  if [ $pids_killed -gt 0 ]; then
    ok "Port-forwards stopped ($pids_killed processes killed)."
  else
    warn "No active port-forward processes found to stop."
  fi
}

check_pf(){
  if [ ! -f "$PF_PIDFILE" ]; then
    echo "❌ No port-forwards running"
    return 1
  fi
  
  local active_count=0
  local total_count=0
  
  while read -r pid; do
    if [ -n "$pid" ]; then
      total_count=$((total_count + 1))
      if kill -0 "$pid" 2>/dev/null; then
        active_count=$((active_count + 1))
      fi
    fi
  done < "$PF_PIDFILE"
  
  if [ $active_count -eq $total_count ] && [ $total_count -gt 0 ]; then
    echo "✅ All $total_count port-forwards are running"
    echo "• Vote   → http://localhost:${VOTE_LOCAL_PORT}"
    echo "• Result → http://localhost:${RESULT_LOCAL_PORT}"
    return 0
  else
    echo "⚠️  $active_count of $total_count port-forwards are running"
    return 1
  fi
}

cleanup(){
  stop_pf || true
  info "Deleting app namespace ${NS_APP}…"
  k delete ns "${NS_APP}" --ignore-not-found
  ok "App cleaned."
}

case "${1:-all}" in
  agent)   install_agent;;
  pullsec) setup_pull_secret;;
  app)     deploy_app;;
  verify)  verify;;
  pf)      start_pf;;
  check)   check_pf;;
  stop)    stop_pf;;
  cleanup) cleanup;;
  pl)       pl_install;;
  unpl)     pl_uninstall;;
  all)      install_agent; setup_pull_secret; deploy_app; verify; start_pf;;
  *) echo "Usage: $0 {all|agent|pullsec|app|verify|pf|check|stop|cleanup|pl|unpl}"; exit 1;;
esac


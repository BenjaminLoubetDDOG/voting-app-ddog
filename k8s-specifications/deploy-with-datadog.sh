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
: "${DD_VERSION:=}"               # Optional: override version (e.g., DD_VERSION=v1.2.3)

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
  local service="$1"
  
  # Option 1: Use environment variable override if set
  if [ -n "${DD_VERSION:-}" ]; then
    echo "${DD_VERSION}"
    return
  fi
  
  # Option 3: Use git commit SHA (short) + timestamp (PRIMARY METHOD)
  local git_sha=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
  local timestamp=$(date +%Y%m%d-%H%M)
  
  # Add dirty flag if there are uncommitted changes
  if git diff --quiet 2>/dev/null && git diff --cached --quiet 2>/dev/null; then
    echo "${git_sha}-${timestamp}"
  else
    echo "${git_sha}-${timestamp}-dirty"
  fi
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
    port: 8125
    useHostPort: true
    nonLocalTraffic: true
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
  info "Setting up port-forwards..."
  
  # Always clean up first (this now kills ALL processes properly)
  stop_pf
  
  # Quick check that deployments exist
  info "Checking deployments..."
  kns get deploy vote result >/dev/null || die "Vote/Result deployments not found"
  
  info "Starting port-forwards..."
  
  # Start port-forwards (simplified - always use port 80 for target)
  kns port-forward svc/vote "${VOTE_LOCAL_PORT}:80" >/dev/null 2>&1 &
  vote_pid=$!
  
  kns port-forward svc/result "${RESULT_LOCAL_PORT}:80" >/dev/null 2>&1 &
  result_pid=$!
  
  # Save PIDs
  {
    echo "$vote_pid"
    echo "$result_pid"
  } > "$PF_PIDFILE"
  
  # Give port-forwards a moment to start
  sleep 3
  
  # Simple verification (just check if processes are still alive)
  if kill -0 "$vote_pid" 2>/dev/null && kill -0 "$result_pid" 2>/dev/null; then
    ok "Port-forwards started:"
    echo "• Vote   → http://localhost:${VOTE_LOCAL_PORT}"  
    echo "• Result → http://localhost:${RESULT_LOCAL_PORT}"
    echo ""
    info "Access your apps in the browser. Use './$(basename "$0") stop' to stop port-forwards."
  else
    warn "Some port-forwards may have failed. Check with './$(basename "$0") check'"
  fi
}

stop_pf(){
  info "Stopping all port-forwards..."
  
  # Kill ALL kubectl port-forward processes (comprehensive cleanup)
  local kubectl_pids=$(pgrep -f "kubectl.*port-forward.*${NS_APP}" 2>/dev/null || true)
  local manual_pids=""
  
  # Also check PID file if it exists
  if [ -f "$PF_PIDFILE" ]; then
    manual_pids=$(cat "$PF_PIDFILE" 2>/dev/null | tr '\n' ' ')
  fi
  
  local all_pids="$kubectl_pids $manual_pids"
  local killed=0
  
  for pid in $all_pids; do
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 0.5
      kill -KILL "$pid" 2>/dev/null || true
      killed=$((killed + 1))
    fi
  done
  
  # Clean up any remaining processes using the ports
  for port in $VOTE_LOCAL_PORT $RESULT_LOCAL_PORT; do
    local port_pid=$(lsof -ti:$port 2>/dev/null || true)
    if [ -n "$port_pid" ]; then
      kill -KILL "$port_pid" 2>/dev/null || true
      killed=$((killed + 1))
    fi
  done
  
  rm -f "$PF_PIDFILE"
  
  if [ $killed -gt 0 ]; then
    ok "Stopped $killed port-forward processes"
  else
    info "No port-forwards to stop"
  fi
}

check_pf(){
  echo "🔍 Port-forward status:"
  
  if [ ! -f "$PF_PIDFILE" ]; then
    echo "❌ No port-forwards running (no PID file)"
    return 1
  fi
  
  local running=0
  local total=0
  
  while read -r pid; do
    if [ -n "$pid" ]; then
      total=$((total + 1))
      if kill -0 "$pid" 2>/dev/null; then
        running=$((running + 1))
      fi
    fi
  done < "$PF_PIDFILE"
  
  # Check if ports are actually listening
  local vote_listening=false
  local result_listening=false
  
  nc -z localhost "$VOTE_LOCAL_PORT" 2>/dev/null && vote_listening=true
  nc -z localhost "$RESULT_LOCAL_PORT" 2>/dev/null && result_listening=true
  
  # Status report
  if [ "$vote_listening" = true ]; then
    echo "✅ Vote   → http://localhost:${VOTE_LOCAL_PORT}"
  else
    echo "❌ Vote   → http://localhost:${VOTE_LOCAL_PORT} (not accessible)"
  fi
  
  if [ "$result_listening" = true ]; then
    echo "✅ Result → http://localhost:${RESULT_LOCAL_PORT}"
  else
    echo "❌ Result → http://localhost:${RESULT_LOCAL_PORT} (not accessible)"
  fi
  
  echo "📊 Processes: $running/$total running"
  
  if [ "$vote_listening" = true ] && [ "$result_listening" = true ]; then
    return 0
  else
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


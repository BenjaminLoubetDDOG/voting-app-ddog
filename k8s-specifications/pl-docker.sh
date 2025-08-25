#!/usr/bin/env bash
set -euo pipefail
CMD="${1:-start}"
CFG="/Users/benjamin.loubet/voting-app-ddog/worker-config-local-demo-894a4dcb8019af2f460ae2efe6473340.json"

case "$CMD" in
  start)
    pkill -f "kubectl.*port-forward.*vote"   || true
    pkill -f "kubectl.*port-forward.*result" || true
    kubectl -n voting-app port-forward svc/vote   8080:8080 >/tmp/pf-vote.log   2>&1 &
    kubectl -n voting-app port-forward svc/result 8081:8081 >/tmp/pf-result.log 2>&1 &
    docker run -d --platform=linux/amd64 --name dd-synth-pl \
      -e DD_LOG_LEVEL=info \
      -v "$CFG:/etc/datadog/synthetics-check-runner.json:ro" \
      gcr.io/datadoghq/synthetics-private-location-worker:1.58.0
    echo "PL running. Use http://host.docker.internal:8080 and :8081 in tests."
    ;;
  stop)
    docker rm -f dd-synth-pl 2>/dev/null || true
    pkill -f "kubectl.*port-forward.*vote"   || true
    pkill -f "kubectl.*port-forward.*result" || true
    echo "Stopped."
    ;;
  logs)
    docker logs -f dd-synth-pl
    ;;
  *)
    echo "Usage: $0 {start|stop|logs}"; exit 1;;
esac


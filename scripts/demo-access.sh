#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# demo-access.sh
# Portable host-side access helper for GitOps thesis demo environments.
# Uses kubectl port-forward to map local/LAN ports to Kubernetes ClusterIP services.
# Does NOT alter Kubernetes manifests, Services, or cluster networking.
# ==============================================================================

BIND_IP="${BIND_IP:-127.0.0.1}"
PID_DIR="/tmp/gitops-thesis-demo-access"

# Endpoints configuration:
# NAME:NAMESPACE:SERVICE:LOCAL_PORT:TARGET_PORT:HEALTH_PATH:IS_HTTPS
ENDPOINTS=(
  "dev-frontend:dev:frontend-service:3000:80:/:false"
  "dev-backend:dev:backend-service:8000:8000:/health:false"
  "qa-frontend:qa:frontend-service:3001:80:/:false"
  "qa-backend:qa:backend-service:8001:8000:/health:false"
  "staging-frontend:staging:frontend-service:3002:80:/:false"
  "staging-backend:staging:backend-service:8002:8000:/health:false"
  "prod-frontend:prod:frontend-service:3003:80:/:false"
  "prod-backend:prod:backend-service:8003:8000:/health:false"
  "argocd-server:argocd:argocd-server:8081:443:/:true"
)

# Tracks forwards successfully started in the current invocation for rollback if needed
STARTED_IN_THIS_RUN=()

# ------------------------------------------------------------------------------
# Pre-flight Checks
# ------------------------------------------------------------------------------
preflight_checks() {
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "ERROR: kubectl command not found in PATH." >&2
    exit 1
  fi

  if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "ERROR: Unable to connect to Kubernetes cluster." >&2
    exit 1
  fi

  local missing_services=()
  for entry in "${ENDPOINTS[@]}"; do
    IFS=":" read -r name ns svc local_port target_port health_path is_https <<< "$entry"
    if ! kubectl get svc -n "$ns" "$svc" >/dev/null 2>&1; then
      missing_services+=("${ns}/${svc}")
    fi
  done

  if [[ ${#missing_services[@]} -gt 0 ]]; then
    echo "ERROR: The following required Kubernetes services were not found:" >&2
    for s in "${missing_services[@]}"; do
      echo "  - $s" >&2
    done
    echo "Aborting before starting any port-forward processes." >&2
    exit 1
  fi
}

# ------------------------------------------------------------------------------
# Port Collision Helper
# ------------------------------------------------------------------------------
is_port_in_use() {
  local port="$1"
  ss -tln | awk '{print $4}' | grep -q -E ":${port}$"
}

# ------------------------------------------------------------------------------
# Rollback helper for partial starts
# ------------------------------------------------------------------------------
rollback_current_run() {
  if [[ ${#STARTED_IN_THIS_RUN[@]} -gt 0 ]]; then
    echo "Rolling back forwards started in this invocation..." >&2
    for item in "${STARTED_IN_THIS_RUN[@]}"; do
      local n="${item%%:*}"
      local p="${item##*:}"
      if kill -0 "$p" 2>/dev/null; then
        kill "$p" 2>/dev/null || true
      fi
      rm -f "${PID_DIR}/${n}.pid"
    done
  fi
}

# ------------------------------------------------------------------------------
# Print URLs Table
# ------------------------------------------------------------------------------
print_urls() {
  cat <<EOF
=============================================================
 GitOps Thesis Demo Endpoints
=============================================================

DEV
Frontend:  http://${BIND_IP}:3000
Backend:   http://${BIND_IP}:8000
Swagger:   http://${BIND_IP}:8000/docs
Health:    http://${BIND_IP}:8000/health

QA
Frontend:  http://${BIND_IP}:3001
Backend:   http://${BIND_IP}:8001
Swagger:   http://${BIND_IP}:8001/docs
Health:    http://${BIND_IP}:8001/health

STAGING
Frontend:  http://${BIND_IP}:3002
Backend:   http://${BIND_IP}:8002
Swagger:   http://${BIND_IP}:8002/docs
Health:    http://${BIND_IP}:8002/health

PROD
Frontend:  http://${BIND_IP}:3003
Backend:   http://${BIND_IP}:8003
Swagger:   http://${BIND_IP}:8003/docs
Health:    http://${BIND_IP}:8003/health

ARGO CD
https://${BIND_IP}:8081

=============================================================
EOF

  if [[ "${BIND_IP}" == "127.0.0.1" ]]; then
    echo "Endpoints are accessible only from this computer."
  else
    echo "Endpoints are bound to ${BIND_IP}. Devices on the same reachable network"
    echo "may access them if the host firewall allows these ports."
  fi
}

# ------------------------------------------------------------------------------
# Endpoint Reachability Verification
# ------------------------------------------------------------------------------
verify_endpoints() {
  echo ""
  echo "Checking endpoint reachability..."
  for entry in "${ENDPOINTS[@]}"; do
    IFS=":" read -r name ns svc local_port target_port health_path is_https <<< "$entry"
    local proto="http"
    local curl_opts=(-s -o /dev/null -w "%{http_code}" --max-time 3)
    if [[ "$is_https" == "true" ]]; then
      proto="https"
      curl_opts+=(-k)
    fi
    local url="${proto}://${BIND_IP}:${local_port}${health_path}"
    local code
    code=$(curl "${curl_opts[@]}" "$url" 2>/dev/null || echo "FAILED")
    if [[ "$code" =~ ^[23] ]]; then
      printf "  [OK]       %-18s (%s) -> HTTP %s\n" "$name" "$url" "$code"
    elif [[ "$code" == "FAILED" ]]; then
      printf "  [UNREACH]  %-18s (%s) -> Connection failed\n" "$name" "$url"
    else
      printf "  [WARN]     %-18s (%s) -> HTTP %s\n" "$name" "$url" "$code"
    fi
  done
}

# ------------------------------------------------------------------------------
# Start Command
# ------------------------------------------------------------------------------
cmd_start() {
  preflight_checks

  mkdir -p "$PID_DIR"

  # Clean up any stale PID files where the process is no longer running
  for entry in "${ENDPOINTS[@]}"; do
    IFS=":" read -r name ns svc local_port target_port health_path is_https <<< "$entry"
    local pidfile="${PID_DIR}/${name}.pid"
    if [[ -f "$pidfile" ]]; then
      local existing_pid
      existing_pid=$(cat "$pidfile" 2>/dev/null || echo "")
      if [[ -z "$existing_pid" ]] || ! kill -0 "$existing_pid" 2>/dev/null; then
        rm -f "$pidfile"
      fi
    fi
  done

  # Launch port forwards sequentially
  for entry in "${ENDPOINTS[@]}"; do
    IFS=":" read -r name ns svc local_port target_port health_path is_https <<< "$entry"
    local pidfile="${PID_DIR}/${name}.pid"
    local logfile="${PID_DIR}/${name}.log"

    # If already running for this endpoint, skip
    if [[ -f "$pidfile" ]]; then
      local existing_pid
      existing_pid=$(cat "$pidfile" 2>/dev/null || echo "")
      if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
        echo "Endpoint ${name} is already running (PID ${existing_pid})."
        continue
      fi
    fi

    # Port collision check before starting each forwarding process
    if is_port_in_use "$local_port"; then
      echo "PORT ${local_port} ALREADY IN USE" >&2
      rollback_current_run
      exit 1
    fi

    echo "Starting port-forward for ${name} (${BIND_IP}:${local_port} -> ${ns}/${svc}:${target_port})..."
    setsid kubectl port-forward \
      --address "$BIND_IP" \
      -n "$ns" \
      "svc/${svc}" \
      "${local_port}:${target_port}" < /dev/null > "$logfile" 2>&1 &
    local pf_pid=$!
    echo "$pf_pid" > "$pidfile"
    STARTED_IN_THIS_RUN+=("${name}:${pf_pid}")

    # Startup verification: check process is alive after brief pause
    sleep 1
    if ! kill -0 "$pf_pid" 2>/dev/null; then
      echo "ERROR: Failed to start port-forward for ${name} (port ${local_port}). Process exited immediately." >&2
      if [[ -f "$logfile" ]]; then
        echo "--- Log output for ${name} ---" >&2
        cat "$logfile" >&2
        echo "------------------------------" >&2
      fi
      rollback_current_run
      exit 1
    fi
  done

  echo ""
  echo "All demo access port-forwards started successfully."
  print_urls
  verify_endpoints
}

# ------------------------------------------------------------------------------
# Stop Command
# ------------------------------------------------------------------------------
cmd_stop() {
  local stopped_count=0
  for entry in "${ENDPOINTS[@]}"; do
    IFS=":" read -r name ns svc local_port target_port health_path is_https <<< "$entry"
    local pidfile="${PID_DIR}/${name}.pid"
    if [[ -f "$pidfile" ]]; then
      local pid
      pid=$(cat "$pidfile" 2>/dev/null || echo "")
      if [[ -n "$pid" ]]; then
        if kill -0 "$pid" 2>/dev/null; then
          # Safety: ensure process command line matches port-forward
          if grep -q "port-forward" "/proc/$pid/cmdline" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            for _ in {1..10}; do
              if ! kill -0 "$pid" 2>/dev/null; then break; fi
              sleep 0.1
            done
            if kill -0 "$pid" 2>/dev/null; then
              kill -9 "$pid" 2>/dev/null || true
            fi
            echo "Stopped ${name} (PID ${pid})"
            ((stopped_count++)) || true
          else
            echo "WARNING: PID ${pid} in ${pidfile} does not match port-forward. Skipping kill." >&2
          fi
        fi
      fi
      rm -f "$pidfile"
    fi
  done

  if [[ $stopped_count -eq 0 ]]; then
    echo "No active port-forward processes found."
  else
    echo "All demo access port-forward processes stopped (${stopped_count} total)."
  fi
}

# ------------------------------------------------------------------------------
# Status Command
# ------------------------------------------------------------------------------
cmd_status() {
  printf "%-18s %-10s %-8s %-12s %-30s\n" "ENDPOINT" "STATUS" "PID" "LOCAL PORT" "TARGET SERVICE"
  printf "%-18s %-10s %-8s %-12s %-30s\n" "----------------" "------" "---" "----------" "--------------"
  for entry in "${ENDPOINTS[@]}"; do
    IFS=":" read -r name ns svc local_port target_port health_path is_https <<< "$entry"
    local pidfile="${PID_DIR}/${name}.pid"
    local status="STOPPED"
    local pid="-"
    if [[ -f "$pidfile" ]]; then
      local candidate
      candidate=$(cat "$pidfile" 2>/dev/null || echo "")
      if [[ -n "$candidate" ]] && kill -0 "$candidate" 2>/dev/null; then
        status="RUNNING"
        pid="$candidate"
      else
        rm -f "$pidfile" 2>/dev/null || true
      fi
    fi
    printf "%-18s %-10s %-8s %-12s %-30s\n" "$name" "$status" "$pid" "$local_port" "${ns}/${svc}:${target_port}"
  done
}

# ------------------------------------------------------------------------------
# Main Dispatcher
# ------------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $0 {start|stop|restart|status|urls}

Commands:
  start    Start all port-forward tunnels
  stop     Stop all port-forward tunnels started by this script
  restart  Restart all port-forward tunnels
  status   Show status of each endpoint port-forward
  urls     Print table of endpoint URLs

Environment Variables:
  BIND_IP  IP address to bind the local listeners (default: 127.0.0.1)
           Example for LAN: BIND_IP=\$(hostname -I | awk '{print \$1}') $0 start
EOF
  exit 1
}

ACTION="${1:-}"
case "$ACTION" in
  start)
    cmd_start
    ;;
  stop)
    cmd_stop
    ;;
  restart)
    cmd_stop
    sleep 1
    cmd_start
    ;;
  status)
    cmd_status
    ;;
  urls)
    print_urls
    ;;
  *)
    usage
    ;;
esac

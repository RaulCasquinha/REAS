#!/usr/bin/env bash
set -euo pipefail

# Prerequisite: run kuber/run-lab.sh first (sections 1-2) so the minikube
# cluster is up and Google Online Boutique is already deployed in the
# "default" namespace. This script only covers the Service Mesh (Istio)
# chapter of the assignment.

# ── colours ──────────────────────────────────────────────────────────────────
C='\033[0;36m'   # cyan  – command
Y='\033[1;33m'   # yellow – prompt / note
G='\033[0;32m'   # green  – section header
R='\033[0;31m'   # red    – error
N='\033[0m'      # reset

LOG="lab_output_$(date +%Y%m%d_%H%M%S).log"
ISTIO_DIR_GLOB="$(pwd)/istio-"*

log()  { printf '%s\n' "$*" | tee -a "$LOG"; }
hdr()  { printf "\n${G}═══ %s ═══${N}\n" "$*" | tee -a "$LOG"; }
note() { printf "${Y}    ↳ %s${N}\n" "$*"; }

# ── GUI checkpoint ────────────────────────────────────────────────────────────
# Pauses and waits for the user to go look at Kiali/Grafana/Jaeger (things the
# CLI can't capture), then records what they saw into the log so it ends up
# in the report alongside the command output.
gui() {
    local prompt="$1"
    printf "\n${Y}  [GUI] %s${N}\n" "$prompt" | tee -a "$LOG"
    printf "${Y}  Press Enter once you've looked, then type what you observed (blank = skip): ${N}"
    read -r observation
    {
        printf "\n[GUI CHECK] %s\n" "$prompt"
        [[ -n "$observation" ]] && printf "Observed: %s\n" "$observation"
    } >> "$LOG"
}

# ── step runner ──────────────────────────────────────────────────────────────
# run "cmd"           – normal command
# run "cmd" 30        – killed after 30 s (for --watch / -f commands)
run() {
    local cmd="$1"
    local timeout_secs="${2:-0}"

    printf "\n${C}\$ %s${N}" "$cmd"
    [[ $timeout_secs -gt 0 ]] && printf " ${Y}(stops after %ss)${N}" "$timeout_secs"
    printf "\n"

    printf "\n\$ %s\n" "$cmd" >> "$LOG"
    [[ $timeout_secs -gt 0 ]] && printf "  [timeout %ss]\n" "$timeout_secs" >> "$LOG"

    if ! $AUTO; then
        printf "${Y}  Enter=run  s=skip  q=quit > ${N}"
        read -r choice
        case "${choice,,}" in
            q) log ""; log "=== session ended by user ==="; exit 0 ;;
            s) log "  (skipped)"; return ;;
        esac
    fi

    if [[ $timeout_secs -gt 0 ]]; then
        timeout "$timeout_secs" bash -c "$cmd" 2>&1 | tee -a "$LOG" || true
        note "watch stopped after ${timeout_secs}s"
        log "  [watch stopped after ${timeout_secs}s]"
    else
        eval "$cmd" 2>&1 | tee -a "$LOG" || true
    fi
}

# ── startup prompt ────────────────────────────────────────────────────────────
clear
printf "${G}"
printf "╔══════════════════════════════════════╗\n"
printf "║   REAS Service Mesh (Istio) Runner   ║\n"
printf "╚══════════════════════════════════════╝\n"
printf "${N}\n"
printf "Output will be saved to: ${C}%s${N}\n\n" "$LOG"

printf "${Y}Group number (NN for reas-gNN.dyn.fil.isel.pt): ${N}"
read -r GROUP_NUM
HOST="reas-g${GROUP_NUM}.dyn.fil.isel.pt"

printf "${Y}Running on the university server? (y/N): ${N}"
read -r on_server
ON_SERVER=false
[[ "${on_server,,}" == "y" ]] && ON_SERVER=true

printf "${Y}Auto mode — run everything without prompts? (y/N): ${N}"
read -r auto
AUTO=false
[[ "${auto,,}" == "y" ]] && AUTO=true

log "=== REAS Service Mesh Lab ==="
log "Date: $(date)"
log "Host: $HOST"
log ""

# ─────────────────────────────────────────────────────────────────────────────
hdr "1 · INSTALL ISTIO"
if command -v istioctl &>/dev/null; then
    note "istioctl already on PATH, skipping download"
    log "  (istioctl found on PATH – download skipped)"
else
    run "curl -L https://istio.io/downloadIstio | sh -"
    note "add istio-*/bin to PATH for this session"
    export PATH="$(ls -d $ISTIO_DIR_GLOB 2>/dev/null | head -1)/bin:$PATH"
fi

run "istioctl install --set profile=demo -y"
run "kubectl label namespace default istio-injection=enabled --overwrite"
run "kubectl get pods -n istio-system"
run "istioctl analyze"

# ─────────────────────────────────────────────────────────────────────────────
hdr "2 · ENABLE SIDECAR INJECTION FOR ONLINE BOUTIQUE"
run "kubectl rollout restart deployment"
run "kubectl wait --for=condition=ready pod --all --timeout=300s"
run "kubectl get pods -o wide"
note "every pod should now show 2/2 containers (application + istio-proxy)"
run "istioctl analyze"

# ─────────────────────────────────────────────────────────────────────────────
hdr "3 · CONFIGURING EXTERNAL ACCESS WITH ISTIO"
if $ON_SERVER; then
    run "ISTIO_HTTP_NODEPORT=\$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name==\"http2\")].nodePort}'); echo \$ISTIO_HTTP_NODEPORT"

    note "removing previous Nginx ingress forwarding (if the k8s lab set it up)"
    run "sudo iptables -t nat -D PREROUTING -p tcp --dport 80 -j DNAT --to-destination \$(minikube ip):80 2>/dev/null || true"
    run "kubectl delete ingress boutique-ingress --ignore-not-found"
    run "minikube addons disable ingress"

    note "forwarding external port 80 to the Istio ingress gateway NodePort"
    run "ISTIO_HTTP_NODEPORT=\$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name==\"http2\")].nodePort}'); sudo iptables -t nat -I PREROUTING 1 -p tcp --dport 80 -j DNAT --to-destination \$(minikube ip):\$ISTIO_HTTP_NODEPORT"
    run "ISTIO_HTTP_NODEPORT=\$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name==\"http2\")].nodePort}'); sudo iptables -I FORWARD 1 -p tcp -d \$(minikube ip) --dport \$ISTIO_HTTP_NODEPORT -j ACCEPT"
    run "sudo netfilter-persistent save"
else
    note "skipping iptables forwarding — only needed on the university server"
    log "  (section 3 iptables skipped – not on university server)"
fi

# ─────────────────────────────────────────────────────────────────────────────
hdr "4 · CREATING ISTIO GATEWAY AND VIRTUALSERVICE"
run "kubectl apply -f frontend-gateway.yaml"
gui "open http://${HOST} in a browser — confirm the shop loads through the Istio gateway"
run "kubectl logs -n istio-system deployment/istio-ingressgateway --tail=50"

# ─────────────────────────────────────────────────────────────────────────────
hdr "5 · OBSERVABILITY ADDONS (Grafana, Prometheus, Jaeger, Kiali)"
ISTIO_DIR="$(ls -d $ISTIO_DIR_GLOB 2>/dev/null | head -1)"
if [[ -n "$ISTIO_DIR" && -d "$ISTIO_DIR/samples/addons" ]]; then
    run "kubectl apply -f ${ISTIO_DIR}/samples/addons/"
else
    note "no local istio-*/samples/addons found — download the istio release if missing"
    log "  (samples/addons not found locally – skipped, download istio release manually)"
fi
run "kubectl wait --for=condition=ready pod --all -n istio-system --timeout=300s"
run "kubectl get pods -n istio-system"

run "kubectl patch svc grafana -n istio-system -p '{\"spec\":{\"type\":\"NodePort\"}}'"
run "kubectl patch svc kiali -n istio-system -p '{\"spec\":{\"type\":\"NodePort\"}}'"
run "kubectl patch svc tracing -n istio-system -p '{\"spec\":{\"type\":\"NodePort\"}}'"
run "kubectl get svc grafana kiali tracing -n istio-system"

if $ON_SERVER; then
    note "forwarding Grafana (3000), Kiali (20001), Jaeger (16686) via iptables"
    run "GRAFANA_NODEPORT=\$(kubectl get svc grafana -n istio-system -o jsonpath='{.spec.ports[0].nodePort}'); KIALI_NODEPORT=\$(kubectl get svc kiali -n istio-system -o jsonpath='{.spec.ports[0].nodePort}'); JAEGER_NODEPORT=\$(kubectl get svc tracing -n istio-system -o jsonpath='{.spec.ports[0].nodePort}'); MINIKUBE_IP=\$(minikube ip); sudo iptables -t nat -I PREROUTING 1 -p tcp --dport 3000 -j DNAT --to-destination \$MINIKUBE_IP:\$GRAFANA_NODEPORT; sudo iptables -t nat -I PREROUTING 1 -p tcp --dport 20001 -j DNAT --to-destination \$MINIKUBE_IP:\$KIALI_NODEPORT; sudo iptables -t nat -I PREROUTING 1 -p tcp --dport 16686 -j DNAT --to-destination \$MINIKUBE_IP:\$JAEGER_NODEPORT; sudo iptables -I FORWARD 1 -p tcp -d \$MINIKUBE_IP --dport \$GRAFANA_NODEPORT -j ACCEPT; sudo iptables -I FORWARD 1 -p tcp -d \$MINIKUBE_IP --dport \$KIALI_NODEPORT -j ACCEPT; sudo iptables -I FORWARD 1 -p tcp -d \$MINIKUBE_IP --dport \$JAEGER_NODEPORT -j ACCEPT"
    note "Grafana  http://${HOST}:3000  ·  Kiali  http://${HOST}:20001  ·  Jaeger  http://${HOST}:16686"
    gui "open Grafana/Kiali/Jaeger above — confirm all three load and show the mesh"
else
    note "skipping iptables forwarding — only needed on the university server"
fi

note "registering the jaeger tracing extension provider (demo profile doesn't define it)"
cat > tracing.yaml << 'EOF'
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  profile: demo
  meshConfig:
    enableTracing: true
    defaultConfig:
      tracing: {}
    extensionProviders:
    - name: jaeger
      opentelemetry:
        port: 4317
        service: jaeger-collector.istio-system.svc.cluster.local
EOF
run "istioctl install -f tracing.yaml -y"
run "kubectl apply -f - <<'EOF'
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: mesh-default
  namespace: istio-system
spec:
  tracing:
  - providers:
    - name: jaeger
    randomSamplingPercentage: 100.0
EOF"

# ─────────────────────────────────────────────────────────────────────────────
hdr "6 · TRAFFIC MANAGEMENT"
note "--- least-request load balancing + connection pool for currencyservice ---"
run "kubectl apply -f currencyservice-lb.yaml"
run "kubectl get destinationrule currencyservice -o yaml"
run "kubectl set env deployment/loadgenerator USERS=50"
run "kubectl logs -l app=currencyservice --tail=5 --prefix"
run "kubectl top pods -l app=currencyservice"

note "--- canary deployment: frontend-v2 + 90/10 traffic split ---"
run "kubectl delete virtualservice frontend --ignore-not-found"
run "kubectl patch deployment frontend -p '{\"spec\":{\"template\":{\"metadata\":{\"labels\":{\"version\":\"v1\"}}}}}'"
run "kubectl get deployment frontend -o yaml | sed -e 's/name: frontend/name: frontend-v2/' -e 's/version: v1/version: v2/' -e 's/:v0\\.[0-9.]*\$/:v0.10.2/' | kubectl apply -f -"
run "kubectl get pods -l app=frontend"
run "kubectl get endpoints frontend"

run "kubectl apply -f frontend-destinationrule.yaml"
run "kubectl apply -f frontend-virtualservice.yaml"
gui "Kiali -> Applications -> frontend -> Traffic Distribution: confirm ~90/10 v1/v2 split"

note "--- shifting the split to 50/50 ---"
run "kubectl patch virtualservice frontend-external --type=json -p='[{\"op\":\"replace\",\"path\":\"/spec/http/0/route/0/weight\",\"value\":50},{\"op\":\"replace\",\"path\":\"/spec/http/0/route/1/weight\",\"value\":50}]'"
run "kubectl patch virtualservice frontend-mesh --type=json -p='[{\"op\":\"replace\",\"path\":\"/spec/http/0/route/0/weight\",\"value\":50},{\"op\":\"replace\",\"path\":\"/spec/http/0/route/1/weight\",\"value\":50}]'"
gui "Kiali -> Applications -> frontend -> Traffic Distribution: confirm ~50/50 v1/v2 split"

note "--- rolling back to 100% v1 ---"
run "kubectl patch virtualservice frontend-external --type=json -p='[{\"op\":\"replace\",\"path\":\"/spec/http/0/route/0/weight\",\"value\":100},{\"op\":\"replace\",\"path\":\"/spec/http/0/route/1/weight\",\"value\":0}]'"
run "kubectl patch virtualservice frontend-mesh --type=json -p='[{\"op\":\"replace\",\"path\":\"/spec/http/0/route/0/weight\",\"value\":100},{\"op\":\"replace\",\"path\":\"/spec/http/0/route/1/weight\",\"value\":0}]'"
run "kubectl delete deployment frontend-v2 --ignore-not-found"

# ─────────────────────────────────────────────────────────────────────────────
hdr "7 · SECURITY — mTLS AND AUTHORIZATION POLICIES"
gui "Kiali -> Graph -> Display -> Security: enable the badge, confirm padlock icons on connections"
run "istioctl proxy-config secret deployment/frontend -o json"
run "kubectl get peerauthentication -A"
note "none found above means PERMISSIVE by default (accepts both mTLS and plaintext)"
note "--- switching to STRICT mTLS ---"
run "kubectl apply -f mtls-strict-policy.yaml"
run "kubectl exec deployment/productcatalogservice -c istio-proxy -- pilot-agent request GET config_dump | grep '\"require_client_certificate\"'"
gui "Grafana Explore -> sum(istio_tcp_connections_opened_total{reporter=\"destination\",connection_security_policy=\"mutual_tls\"}) — record the mTLS connection count"

note "--- authorization policy: only frontend may call productcatalogservice ---"
run "kubectl create serviceaccount frontend -n default --dry-run=client -o yaml | kubectl apply -f -"
run "kubectl create serviceaccount productcatalogservice -n default --dry-run=client -o yaml | kubectl apply -f -"
run "kubectl patch deployment frontend -p '{\"spec\":{\"template\":{\"spec\":{\"serviceAccountName\":\"frontend\"}}}}'"
run "kubectl patch deployment productcatalogservice -p '{\"spec\":{\"template\":{\"spec\":{\"serviceAccountName\":\"productcatalogservice\"}}}}'"

run "kubectl apply -f productcatalog-authz.yaml"
run "kubectl describe authorizationpolicy productcatalog-access"
gui "Kiali -> Graph -> Display -> Security: confirm denied requests from non-frontend callers"

note "--- restoring open access ---"
run "kubectl delete authorizationpolicy productcatalog-access"

note "--- default-deny: block ALL traffic to ALL services (demonstration only) ---"
run "kubectl apply -f default-deny-policy.yaml"
gui "open http://${HOST} — app should be broken; Kiali should show all connections red with RBAC errors"
run "kubectl delete authorizationpolicy deny-all"

# ─────────────────────────────────────────────────────────────────────────────
hdr "8 · FAULT INJECTION AND CIRCUIT BREAKER"
note "--- 5s delay on 50% of currencyservice requests ---"
run "kubectl apply -f currencyservice-delay.yaml"
run "kubectl logs deployment/frontend -c server --tail=20" 20
gui "open http://${HOST} (expect 5+s page loads); check Grafana p95/p99 spike to ~5000ms and Jaeger for a >5s currencyservice span"
run "kubectl delete virtualservice currencyservice-delay"

note "--- HTTP 503 abort on 30% of mesh-internal frontend traffic ---"
run "kubectl apply -f frontend-abort.yaml"
run "kubectl logs -l app=loadgenerator --tail=50"
gui "Kiali -> Graph -> Display -> HTTP Traffic: loadgenerator->frontend edge should show ~30% red (503s)"
run "kubectl delete virtualservice frontend-mesh"

note "--- enabling circuit-breaker statistics on loadgenerator and frontend ---"
run "kubectl annotate deployment loadgenerator proxy.istio.io/config='proxyStatsMatcher:
  inclusionRegexps:
  - \".*outlier_detection.*\"
  - \".*upstream_rq_retry.*\"
  - \".*upstream_cx_.*\"
  inclusionSuffixes:
  - \"upstream_rq_timeout\"
  - \"upstream_rq_pending_overflow\"' --overwrite"
run "kubectl annotate deployment frontend proxy.istio.io/config='proxyStatsMatcher:
  inclusionRegexps:
  - \".*outlier_detection.*\"
  - \".*upstream_rq_retry.*\"
  - \".*upstream_cx_.*\"
  inclusionSuffixes:
  - \"upstream_rq_timeout\"
  - \"upstream_rq_pending_overflow\"' --overwrite"
run "kubectl rollout restart deployment loadgenerator frontend"
run "kubectl rollout status deployment loadgenerator"
run "kubectl rollout status deployment frontend"
run "kubectl exec deployment/loadgenerator -c istio-proxy -- curl -s http://localhost:15090/stats/prometheus | grep outlier"

note "--- configuring an aggressive circuit breaker on frontend ---"
run "kubectl scale deployment frontend --replicas=3"
run "kubectl set env deployment/loadgenerator USERS=30"
run "kubectl apply -f frontend-circuitbreaker.yaml"
run "kubectl exec deployment/frontend -c istio-proxy -- pilot-agent request GET config_dump | grep -A 20 outlier_detection"

note "--- triggering ejections: starve frontend of resources + raise load ---"
run "kubectl patch deployment frontend --type='json' -p='[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/resources\",\"value\":{\"requests\":{\"cpu\":\"5m\",\"memory\":\"20Mi\"},\"limits\":{\"cpu\":\"10m\",\"memory\":\"30Mi\"}}}]'"
run "kubectl set env deployment/loadgenerator USERS=200"
note "waiting 90s for pods to restart and feel the resource pressure..."
sleep 90
run "kubectl exec deployment/loadgenerator -c istio-proxy -- curl -s http://localhost:15090/stats/prometheus | grep pending_overflow"
run "kubectl exec deployment/loadgenerator -c istio-proxy -- curl -s http://localhost:15090/stats/prometheus | grep ejections"
run "kubectl exec deployment/loadgenerator -c istio-proxy -- curl -s http://localhost:15000/clusters | grep 'outbound|80||frontend' | grep health_flags"
gui "Grafana Explore -> envoy_cluster_outlier_detection_ejections_active{cluster_name=~\".*frontend.*\"} — record active ejections, and whether you see recovery cycles"

note "--- cleanup: removing fault/circuit-breaker config, restoring frontend ---"
run "kubectl delete virtualservice --all"
run "kubectl delete destinationrule --all"
run "kubectl set env deployment/loadgenerator USERS=30"
run "kubectl apply -f frontend-gateway.yaml"
run "kubectl scale deployment frontend --replicas=3"
run "kubectl patch deployment frontend --type=json -p='[{\"op\":\"remove\",\"path\":\"/spec/template/spec/containers/0/resources\"}]'"
run "kubectl apply -f currencyservice-lb.yaml"

# ─────────────────────────────────────────────────────────────────────────────
hdr "9 · PERFORMANCE ANALYSIS"

note "--- baseline metrics collection (sidecars injected, mTLS PERMISSIVE) ---"
run "kubectl apply -f mtls-permissive-policy.yaml"
run "kubectl top pods --sort-by=memory > baseline-resources.txt; cat baseline-resources.txt"
run "kubectl top nodes > baseline-nodes.txt; cat baseline-nodes.txt"
note "Grafana Explore (http://${HOST}:3000), run each PromQL query below and record the value:"
gui "sum(rate(istio_requests_total{destination_service=\"frontend.default.svc.cluster.local\"}[1m])) — frontend req/s"
gui "histogram_quantile(0.50, sum(rate(istio_request_duration_milliseconds_bucket{destination_service=\"frontend.default.svc.cluster.local\"}[1m])) by (le)) — P50 latency (ms)"
gui "histogram_quantile(0.95, sum(rate(istio_request_duration_milliseconds_bucket{destination_service=\"frontend.default.svc.cluster.local\"}[1m])) by (le)) — P95 latency (ms)"
gui "histogram_quantile(0.99, sum(rate(istio_request_duration_milliseconds_bucket{destination_service=\"frontend.default.svc.cluster.local\"}[1m])) by (le)) — P99 latency (ms)"

note "--- sidecar proxy overhead: server vs istio-proxy per pod ---"
run "kubectl top pods --containers"

note "--- mTLS performance impact: PERMISSIVE -> STRICT ---"
run "kubectl apply -f mtls-strict-policy.yaml"
note "waiting 2min for config propagation..."
sleep 120
run "kubectl top pods --sort-by=memory > strict-mtls-resources.txt; cat strict-mtls-resources.txt"
gui "re-run the P50/P95/P99 Grafana queries above under STRICT — record and compare against the PERMISSIVE values"

note "--- traffic management overhead: baseline / routing / canary / circuit breaker / LB algorithm ---"
run "kubectl delete virtualservice,destinationrule --all"
run "kubectl top pods -l app=frontend"
note "record this as the 'Baseline (no rules)' row, then apply each config below in turn"
for cfg in frontend-simple frontend-canary frontend-with-cb frontend-lb-rr frontend-lb-lc frontend-lb-random; do
    hdr "  config: ${cfg}.yaml"
    run "kubectl apply -f ${cfg}.yaml"
    note "waiting 30s for config propagation..."
    sleep 30
    run "kubectl top pods -l app=frontend"
    gui "Grafana P50/P95/P99/req-s for config '${cfg}' — record before deleting it"
    run "kubectl delete -f ${cfg}.yaml"
done
run "kubectl apply -f frontend-gateway.yaml"
run "kubectl apply -f currencyservice-lb.yaml"

note "--- control plane resource usage ---"
run "kubectl top pods -n istio-system"

note "--- latency breakdown with distributed tracing ---"
run "kubectl set env deployment/loadgenerator USERS=50"
gui "Jaeger (http://${HOST}:16686): service frontend.default, find a multi-service trace (e.g. checkout), expand it — record per-span Istio/Envoy overhead"

# ─────────────────────────────────────────────────────────────────────────────
hdr "DONE"
printf "\n${G}All sections complete.${N}\n"
printf "Report output saved to: ${C}%s${N}\n\n" "$LOG"

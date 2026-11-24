#!/usr/bin/env bash
set -euo pipefail

# ── colours ──────────────────────────────────────────────────────────────────
C='\033[0;36m'   # cyan  – command
Y='\033[1;33m'   # yellow – prompt / note
G='\033[0;32m'   # green  – section header
R='\033[0;31m'   # red    – error
N='\033[0m'      # reset

LOG="lab_output_$(date +%Y%m%d_%H%M%S).log"
DEMO_DIR="$(pwd)/microservices-demo"

log()  { printf '%s\n' "$*" | tee -a "$LOG"; }
hdr()  { printf "\n${G}═══ %s ═══${N}\n" "$*" | tee -a "$LOG"; }
note() { printf "${Y}    ↳ %s${N}\n" "$*"; }

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
printf "║     REAS Kubernetes Lab Runner       ║\n"
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

log "=== REAS Kubernetes Lab ==="
log "Date: $(date)"
log "Host: $HOST"
log ""

# ─────────────────────────────────────────────────────────────────────────────
hdr "1 · START CLUSTER"
run "minikube start --driver=docker --cpus=4 --memory=8192"
run "kubectl cluster-info"
run "kubectl get nodes"
run "kubectl get pods -n kube-system"

# ─────────────────────────────────────────────────────────────────────────────
hdr "2 · DEPLOY GOOGLE ONLINE BOUTIQUE"
if [[ ! -d "$DEMO_DIR" ]]; then
    run "git clone --depth 1 --branch v0 https://github.com/GoogleCloudPlatform/microservices-demo.git"
else
    note "microservices-demo already cloned, skipping git clone"
    log "  (git clone skipped – directory exists)"
fi
run "kubectl apply -f ${DEMO_DIR}/release/kubernetes-manifests.yaml"
run "kubectl wait --for=condition=ready pod --all --timeout=300s"
run "kubectl get pods"
run "kubectl get services"
run "minikube service frontend-external"

# ─────────────────────────────────────────────────────────────────────────────
hdr "3 · EXPLORE DEPLOYMENT"
run "kubectl get pods -o wide"

note "--- currencyservice deployment ---"
run "kubectl get deployment currencyservice -o yaml"
run "kubectl get deployment currencyservice -o jsonpath='{.spec.replicas}'"
run "kubectl get deployment currencyservice -o jsonpath='{.spec.template.spec.containers[0].resources}' | jq"
run "kubectl get deployment currencyservice -o jsonpath='{.spec.template.spec.containers[0].image}'"

note "--- frontend service ---"
run "kubectl get service frontend -o yaml"
run "kubectl describe service frontend"

# ─────────────────────────────────────────────────────────────────────────────
hdr "4 · EXTERNAL ACCESS — INGRESS"
if $ON_SERVER; then
    run "minikube addons enable ingress"
    note "creating boutique-ingress.yaml for host: $HOST"

    cat > boutique-ingress.yaml << EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: boutique-ingress
  namespace: default
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "600"
spec:
  ingressClassName: nginx
  rules:
  - host: ${HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: frontend
            port:
              number: 80
EOF
    log "  (boutique-ingress.yaml written for host: $HOST)"

    run "kubectl apply -f boutique-ingress.yaml"
    run "kubectl describe ingress boutique-ingress"
    run "kubectl get svc -n ingress-nginx"

    run "minikube ip"
    MINIKUBE_IP=$(minikube ip 2>/dev/null || echo "192.168.49.2")

    run "sudo iptables -t nat -I PREROUTING 1 -p tcp --dport 80 -j DNAT --to-destination ${MINIKUBE_IP}:80"
    run "sudo iptables -I FORWARD 1 -p tcp -d ${MINIKUBE_IP} --dport 80 -j ACCEPT"
    run "sudo sh -c 'echo 1 > /proc/sys/net/ipv4/ip_forward'"
    run "sudo apt install -y iptables-persistent"
    run "sudo netfilter-persistent save"
else
    note "skipping ingress/iptables — only needed on the university server"
    log "  (section 4 skipped – not on university server)"
fi

# ─────────────────────────────────────────────────────────────────────────────
hdr "5 · METRICS AND MONITORING"
run "minikube addons enable metrics-server"
note "waiting for metrics-server to become ready..."
until kubectl top nodes &>/dev/null; do sleep 5; done
log "  (metrics-server ready)"
run "kubectl top nodes"
run "kubectl top pods"
run "kubectl describe node minikube"
run "kubectl get events --sort-by='.lastTimestamp'"
run "kubectl top pods -l app=currencyservice"
run "kubectl top pods -l app=productcatalogservice"

# ─────────────────────────────────────────────────────────────────────────────
hdr "6 · MANUAL SCALING — FRONTEND"
note "--- 1 replica (baseline) ---"
run "kubectl scale deployment frontend --replicas=1"
run "kubectl wait --for=condition=ready pod -l app=frontend --timeout=60s"
run "kubectl top pods -l app=frontend"

note "--- 3 replicas ---"
run "kubectl scale deployment frontend --replicas=3"
run "kubectl wait --for=condition=ready pod -l app=frontend --timeout=60s"
run "kubectl top pods -l app=frontend"

note "--- 5 replicas ---"
run "kubectl scale deployment frontend --replicas=5"
run "kubectl wait --for=condition=ready pod -l app=frontend --timeout=60s"
run "kubectl top pods -l app=frontend"

note "scaling back to 1 for HPA test"
run "kubectl scale deployment frontend --replicas=1"

# ─────────────────────────────────────────────────────────────────────────────
hdr "7 · HORIZONTAL POD AUTOSCALER (HPA)"
run "kubectl get deployment currencyservice -o jsonpath='{.spec.template.spec.containers[0].resources}' | jq"
note "if resources are missing, patching them now..."
run "kubectl patch deployment currencyservice -p '{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"server\",\"resources\":{\"requests\":{\"memory\":\"64Mi\",\"cpu\":\"100m\"},\"limits\":{\"memory\":\"128Mi\",\"cpu\":\"200m\"}}}]}}}}'"

cat > currencyservice-hpa.yaml << 'EOF'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: currencyservice-hpa
  namespace: default
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: currencyservice
  minReplicas: 1
  maxReplicas: 5
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
EOF
log "  (currencyservice-hpa.yaml written)"

run "kubectl apply -f currencyservice-hpa.yaml"
run "kubectl get hpa currencyservice-hpa"

# ─────────────────────────────────────────────────────────────────────────────
hdr "8 · LOAD GENERATOR EXPERIMENTS"
run "kubectl get pods -l app=loadgenerator"
run "kubectl describe deployment loadgenerator"
run "kubectl get deployment loadgenerator -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name==\"USERS\")].value}'"

for users in 10 50 100 200; do
    hdr "  Load: USERS=${users}"
    run "kubectl set env deployment/loadgenerator USERS=${users}"
    note "waiting 2 min for load to stabilise and HPA to react..."
    sleep 120
    run "kubectl get hpa currencyservice-hpa"
    run "kubectl get pods -l app=currencyservice"
    run "kubectl top pods -l app=currencyservice"
    run "kubectl logs deployment/loadgenerator --tail=20"
done

note "--- watch HPA for 60 s at peak load ---"
run "kubectl get hpa currencyservice-hpa --watch" 60

note "restoring default load"
run "kubectl set env deployment/loadgenerator USERS=10"

# ─────────────────────────────────────────────────────────────────────────────
hdr "9 · ROLLING UPDATE AND ROLLBACK"
run "kubectl get deployment frontend -o jsonpath='{.spec.template.spec.containers[0].image}'"
run "kubectl rollout history deployment/frontend"

note "rolling to v0.10.2"
run "kubectl set image deployment/frontend server=us-central1-docker.pkg.dev/google-samples/microservices-demo/frontend:v0.10.2"
run "kubectl rollout status deployment/frontend"
run "kubectl rollout history deployment/frontend"
run "kubectl get pods -l app=frontend --watch" 30
run "kubectl rollout history deployment/frontend --revision=2"

note "rolling back"
run "kubectl rollout undo deployment/frontend"
run "kubectl rollout status deployment/frontend"
run "kubectl rollout history deployment/frontend"

# ─────────────────────────────────────────────────────────────────────────────
hdr "10 · HEALTH CHECKS"
run "kubectl describe deployment currencyservice"
run "kubectl describe deployment frontend"

# ─────────────────────────────────────────────────────────────────────────────
hdr "11 · SERVICE DISCOVERY"
run "kubectl exec -it deployment/redis-cart -- nslookup productcatalogservice"
run "kubectl describe service productcatalogservice"

# ─────────────────────────────────────────────────────────────────────────────
hdr "DONE"
printf "\n${G}All sections complete.${N}\n"
printf "Report output saved to: ${C}%s${N}\n\n" "$LOG"

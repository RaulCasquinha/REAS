#!/usr/bin/env bash
set -euo pipefail

# Quick start/kill helper for the Istio layer on top of the existing
# minikube cluster. This manages Istio only — it assumes the cluster
# itself (and Online Boutique) is already up via kuber/cluster.sh and
# kuber/run-lab.sh. Use kuber/cluster.sh to start/kill the cluster itself.

C='\033[0;36m'
Y='\033[1;33m'
G='\033[0;32m'
R='\033[0;31m'
N='\033[0m'

usage() {
    printf "Usage: %s {start|kill|status}\n\n" "$0"
    printf "  start   install Istio (if needed), enable sidecar injection,\n"
    printf "          restart Online Boutique deployments to inject sidecars\n"
    printf "  kill    disable sidecar injection, strip sidecars, uninstall Istio\n"
    printf "  status  show istio-system pods and whether sidecars are injected\n"
    exit 1
}

[[ $# -eq 1 ]] || usage

case "$1" in
    start)
        if kubectl get ns istio-system &>/dev/null; then
            printf "${Y}==> istio-system namespace already exists, skipping istioctl install${N}\n"
        else
            printf "${G}==> installing Istio (profile=demo)${N}\n"
            istioctl install --set profile=demo -y
        fi
        printf "${G}==> enabling sidecar injection on default namespace${N}\n"
        kubectl label namespace default istio-injection=enabled --overwrite
        printf "${G}==> restarting deployments to inject sidecars${N}\n"
        kubectl rollout restart deployment
        kubectl wait --for=condition=ready pod --all --timeout=300s
        kubectl get pods -o wide
        istioctl analyze
        ;;

    kill)
        printf "${R}This will remove Istio sidecars/control plane from the cluster${N}\n"
        printf "${Y}Are you sure? (y/N): ${N}"
        read -r confirm
        if [[ "${confirm,,}" != "y" ]]; then
            printf "Aborted.\n"
            exit 0
        fi
        printf "${G}==> removing mesh config (VirtualServices, DestinationRules, AuthorizationPolicies)${N}\n"
        kubectl delete virtualservice --all --ignore-not-found
        kubectl delete destinationrule --all --ignore-not-found
        kubectl delete authorizationpolicy --all --ignore-not-found
        kubectl delete peerauthentication --all --ignore-not-found

        printf "${G}==> disabling sidecar injection and restarting deployments${N}\n"
        kubectl label namespace default istio-injection- --overwrite
        kubectl rollout restart deployment
        kubectl wait --for=condition=ready pod --all --timeout=300s

        printf "${G}==> uninstalling Istio control plane${N}\n"
        istioctl uninstall --purge -y
        kubectl delete namespace istio-system --ignore-not-found
        ;;

    status)
        if kubectl get ns istio-system &>/dev/null; then
            printf "${G}==> Istio control plane:${N}\n"
            kubectl get pods -n istio-system
            printf "\n${G}==> sidecar injection (default namespace):${N}\n"
            kubectl get namespace default --show-labels
            printf "\n${G}==> pod sidecar status:${N}\n"
            kubectl get pods -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[*].name'
        else
            printf "${R}==> Istio is not installed${N}\n"
        fi
        ;;

    *)
        usage
        ;;
esac

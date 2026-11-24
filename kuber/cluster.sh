#!/usr/bin/env bash
set -euo pipefail

# Quick start/kill helper for the minikube cluster used by run-lab.sh.
# This manages the cluster itself (VM/container + control plane). It does
# NOT touch Online Boutique or Istio — use servicemesh/cluster.sh to
# start/kill just the Istio layer on top of this cluster.

C='\033[0;36m'
Y='\033[1;33m'
G='\033[0;32m'
R='\033[0;31m'
N='\033[0m'

usage() {
    printf "Usage: %s {start|kill|status}\n\n" "$0"
    printf "  start   minikube start --driver=docker --cpus=4 --memory=8192\n"
    printf "  kill    tear down the cluster completely (minikube delete)\n"
    printf "  status  show whether the cluster is up and list nodes/pods\n"
    exit 1
}

[[ $# -eq 1 ]] || usage

case "$1" in
    start)
        printf "${G}==> starting minikube${N}\n"
        minikube start --driver=docker --cpus=4 --memory=8192
        kubectl cluster-info
        kubectl get nodes
        ;;

    kill)
        printf "${R}This will delete the minikube cluster and everything running on it${N}\n"
        printf "${Y}Are you sure? (y/N): ${N}"
        read -r confirm
        if [[ "${confirm,,}" != "y" ]]; then
            printf "Aborted.\n"
            exit 0
        fi
        printf "${G}==> deleting minikube cluster${N}\n"
        minikube delete
        ;;

    status)
        if minikube status &>/dev/null; then
            printf "${G}==> cluster is up${N}\n"
            minikube status
            kubectl get nodes
            kubectl get pods -A
        else
            printf "${R}==> cluster is not running${N}\n"
        fi
        ;;

    *)
        usage
        ;;
esac

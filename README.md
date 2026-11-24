# REAS — Applications and Services Delivery Networks

**Redes de Entrega de Aplicações e Serviços**

Coursework deliverable: progressively build an applications/services delivery stack — from a
single web server, through load-balanced/clustered WordPress, to a Kubernetes-orchestrated
microservices app, to a full Istio service mesh on top of it. Full assignment brief:
[`docs/work/work_instructions.md`](docs/work/work_instructions.md).

```mermaid
flowchart TD
    subgraph CH1["wordpress/ — Load Balancing"]
        A1["01-single-service<br/>WordPress + MariaDB"]
        A2["02-load-balancing<br/>Nginx + 3x WordPress"]
        A3["03-backend-bottleneck<br/>Nginx + 3x WordPress + Galera cluster"]
        A1 --> A2 --> A3
    end

    subgraph CH2["kuber/ — Kubernetes"]
        B1["Minikube cluster"]
        B2["Google Online Boutique<br/>(11 microservices)"]
        B3["Scaling · HPA · Rolling updates<br/>Service discovery · Self-healing"]
        B1 --> B2 --> B3
    end

    subgraph CH3["servicemesh/ — Istio"]
        C1["Istio control plane<br/>+ Envoy sidecars"]
        C2["Traffic mgmt · mTLS · AuthZ<br/>Observability · Fault injection"]
        C1 --> C2
    end

    CH1 -.concepts carry forward.-> CH2
    CH2 -->|cluster + app already running| CH3

    R["docs/report/ — written report"]
    CH1 --> R
    CH2 --> R
    CH3 --> R
```

## Repository layout

| Folder | Chapter | Status |
|---|---|---|
| [`wordpress/`](wordpress/README.md) | Load testing, horizontal scaling, backend bottleneck | Configs ready, not yet benchmarked |
| [`kuber/`](kuber/README.md) | Container orchestration with Kubernetes | Complete, logged, validated |
| [`servicemesh/`](servicemesh/README.md) | Service mesh with Istio | Scripted, not yet executed |
| [`docs/work/`](docs/work/README.md) | Assignment brief | — |
| [`docs/report/`](docs/report/README.md) | Written report (LaTeX) | In progress |

Each folder above has its own `README.md` with setup/usage instructions, and most have a
`README-nixos.md` + `shell.nix` for NixOS users.

## Quick start

1. **WordPress chapter** — `cd wordpress && ./apply-config.sh` to pick a configuration.
2. **Kubernetes chapter** — `cd kuber && ./cluster.sh start` then `./run-lab.sh`.
3. **Service Mesh chapter** — `cd servicemesh && ./cluster.sh start` then `./run-lab.sh`
   (requires the Kubernetes chapter's cluster to already be up).

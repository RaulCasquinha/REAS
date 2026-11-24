# WordPress Load Balancing Lab — NixOS Guide

Enter the shell to get `docker-compose` and `jq` from nixpkgs (the Docker **daemon** itself still
needs to be enabled in your system `configuration.nix` — `virtualisation.docker.enable = true;` —
nix-shell only provides the CLI):

```bash
nix-shell
```

## Prerequisites

- Docker daemon running on the host (via `virtualisation.docker.enable = true;` + `nixos-rebuild switch`).
- Apache JMeter on your **client** machine (not the VM) — https://jmeter.apache.org, or
  `nix-shell -p jmeter` for a quick local run.

---

## 1. Configurations available

| Folder | Stage | What it is |
|---|---|---|
| `01-single-service/` | Load Testing (baseline) | Single WordPress + single MariaDB |
| `02-load-balancing/` | Horizontal Scaling and Load Balancing | 3 WordPress replicas behind Nginx (round-robin), port 80 |
| `03-backend-bottleneck/` | Handling Bottleneck at the Backend | 3 WordPress replicas + 3-node MariaDB Galera cluster behind Nginx |

```bash
./apply-config.sh
```

Pick a config by number; it stops whatever's active, copies the chosen config into `active/`, and
runs `docker compose up -d`.

---

## 2. Benchmarking with JMeter

Same procedure as the Ubuntu guide (`README.md` §2) — reuse one Test Plan across all three
configs, point it at `http://reas-gNN.dyn.fil.isel.pt`, and record requests/sec, average response
time, error rate %, and `docker stats` output for each configuration before switching to the next.

---

## 3. Galera cluster notes (`03-backend-bottleneck`)

Same caveat as the Ubuntu guide: never restart `db` while `db2`/`db3` are up without first removing
`--wsrep-new-cluster` from its command, or it forks a new cluster instead of rejoining. Check with:

```bash
docker compose -f active/docker-compose.yml exec db mysql -uroot -preas2024 -e "SHOW GLOBAL STATUS LIKE 'wsrep_%';"
```

---

## Cleanup

```bash
docker compose -f active/docker-compose.yml down -v
```

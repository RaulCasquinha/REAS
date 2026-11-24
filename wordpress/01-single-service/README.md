# 01-single-service

Baseline: a single WordPress instance backed by a single MariaDB database, no load balancer.
This is the "Load Testing" chapter's starting point — every other configuration in this lab is
measured against this baseline.

```mermaid
flowchart LR
    Client["JMeter / Browser"] -->|port 80| WP["wordpress"]
    WP --> DB["db (MariaDB)"]
```

Apply with `../apply-config.sh` (option 1), or directly:

```bash
docker compose up -d
```

WordPress is served on port 80.

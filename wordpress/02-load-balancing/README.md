# 02-load-balancing

"Horizontal Scaling and Load Balancing" chapter: 3 WordPress replicas sharing one MariaDB
instance and one `wp_data` volume (so login sessions survive across containers), fronted by
Nginx doing round-robin load balancing.

```mermaid
flowchart LR
    Client["JMeter / Browser"] -->|port 80| Nginx["nginx<br/>round-robin"]
    Nginx --> W1["wordpress1"]
    Nginx --> W2["wordpress2"]
    Nginx --> W3["wordpress3"]
    W1 --> DB["db (MariaDB)"]
    W2 --> DB
    W3 --> DB
    W1 -.shared volume.- W2
    W2 -.shared volume.- W3
```

Apply with `../apply-config.sh` (option 2), or directly:

```bash
docker compose up -d
```

`nginx.conf`'s `upstream` block defaults to round-robin. To compare load-balancing algorithms
(as the brief asks), edit the `upstream backends { ... }` block to add `least_conn;` or
`ip_hash;`, then `docker compose restart nginx` and rerun your JMeter test plan between edits.

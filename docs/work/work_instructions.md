# Applications and Services Delivery Networks — Web Performance Project

*Author: Nuno Cruz — V2.3 (converted from `work_instructions.pdf`)*

This coursework aims to provide students with hands-on experience of configuring and evaluating
the performance of applications and services delivery networks. Students will implement various
components required for a functional application and service delivery infrastructure.

The tasks cover load balancing, web caching, HTTP/2 and HTTP/3, container orchestration with
Kubernetes, and service mesh technologies with Istio. Students will start by benchmarking the
performance of a single web server, then progressively add components like reverse proxies,
database clustering, containers, autoscaling, and a service mesh to build a resilient and efficient
system.

The practical experiments allow students to gain expertise in measuring key metrics like latency,
throughput and scalability. They will compare different solutions, such as load balancing with
Nginx, Kubernetes Services and Istio traffic management, to discover the pros and cons of each
approach. Monitoring and visualisation tools will be utilised to observe real-time behaviour.

By the end of the coursework, students will have built an end-to-end applications and services
delivery architecture using virtualised infrastructure (Docker, Minikube and Istio). The final report
will analyse the configurations and results, providing a comparison of the tested methodologies.

During this project, we expect that you deliver one written report by the end of the semester that
will summarize your efforts on reaching the objective.

For this you need a Virtual Machine with Linux installed. We will use the VMs available at the lab
with the following details, where `NN` is your group number (e.g. `reas-g01` is the group 1
hostname):

- **VM Host:** `reas-gNN.dyn.fil.isel.pt`
- **User:** `student`
- **Password:** `student`

After logging in via SSH, install Docker using the [official guide](https://docs.docker.com/engine/install/ubuntu/), then let your user use docker:

```bash
$ sudo usermod -aG docker $USER
```

---

## Getting Started With Performance Measurement Tools

Various industry-standard tools exist for load testing and benchmarking web servers/applications.
We use **Apache JMeter** (https://jmeter.apache.org). Start by benchmarking public cloud servers
(e.g. Google) and internal ISEL servers to ensure parameters work for different scenarios.

JMeter's automated feature can record Test Plans (see the [proxy step-by-step guide](https://jmeter.apache.org/usermanual/jmeter_proxy_step_by_step.html)). Reuse the same parameters (threads, ramp-up, test count) across all subsequent tests for comparable results.

Key things to measure: latency, requests per second (transactions), throughput, errors, and
resource utilization (client and server side). Also look at caching efficiency and SSL handshake
times where applicable.

JMeter produces an HTML report with all measurements and graphics.

---

## Load Testing

Use Docker to spin up a standardized, reproducible WordPress + MariaDB environment via
`docker-compose.yml`:

```yaml
services:
  db:
    image: mariadb:latest
    volumes:
      - db_data:/var/lib/mysql
    restart: always
    environment:
      - MYSQL_ROOT_PASSWORD=reas2024
      - MYSQL_DATABASE=wordpress
      - MYSQL_USER=wordpress
      - MYSQL_PASSWORD=wordpress
    expose:
      - 3306
      - 33060
  wordpress:
    image: wordpress:latest
    volumes:
      - wp_data:/var/www/html
    ports:
      - 80:80
    restart: always
    environment:
      - WORDPRESS_DB_HOST=db
      - WORDPRESS_DB_USER=wordpress
      - WORDPRESS_DB_PASSWORD=wordpress
      - WORDPRESS_DB_NAME=wordpress
volumes:
  db_data:
  wp_data:
```

Run `docker compose up` (`-d` for daemon mode). WordPress is served on port 80. From the host,
run Apache JMeter against it (Load testing host = client, Services VM = Docker containers).
You can also split VMs across two computers to test network impact.

### Horizontal Scaling and Load Balancing

Scale WordPress to 3 replicas (`wordpress1`, `wordpress2`, `wordpress3`), sharing the same volume
so user sessions survive across containers. Add an Nginx reverse proxy/load balancer:

```yaml
nginx:
  image: nginx:latest
  ports:
    - 80:80
  depends_on:
    - wordpress1
    - wordpress2
    - wordpress3
  volumes:
    - ./nginx.conf:/etc/nginx/nginx.conf
```

`nginx.conf` (round robin):

```nginx
upstream backends {
  server wordpress1;
  server wordpress2;
  server wordpress3;
}

server {
  location / {
    proxy_pass http://backends;
    proxy_set_header Host $host;
  }
}
```

If using the lab name (`dyn.users.fil.isel.pt`), use that instead of `backends`. Rerun JMeter and
compare against the single-instance baseline. Metrics to evaluate: requests/sec, average response
time, error rate %. Experiment with Nginx LB algorithms (least connections, IP hash). Then enable
Nginx caching and re-evaluate, checking HTTP cache headers.

### Handling Bottleneck at the Backend

A single MySQL/MariaDB instance becomes a bottleneck as load increases. Two scaling options:

1. **Replication** — master/slave, reads from slaves, writes to master; simpler architecture, single
   write point.
2. **Clustering (Galera)** — sharding across nodes; horizontal scalability, no single point of failure.

Example Galera cluster via Docker Compose (3 MariaDB nodes, first bootstrapped with
`--wsrep-new-cluster`, others joining via `wsrep_cluster_address`, SST via `mariabackup`):

```yaml
services:
  db:
    image: mariadb:11
    command: >
      --wsrep-on=ON
      --wsrep-provider=/usr/lib/galera/libgalera_smm.so
      --wsrep-cluster-name=wp_cluster
      --wsrep-cluster-address=gcomm://
      --wsrep-node-name=db
      --wsrep-node-address=db
      --wsrep-sst-method=mariabackup
      --wsrep-sst-auth=root:reas2024
      --wsrep-new-cluster
      --binlog-format=ROW
      --default-storage-engine=InnoDB
      --innodb-autoinc-lock-mode=2
    environment:
      - MARIADB_ROOT_PASSWORD=reas2024
      - MARIADB_USER=wordpress
      - MARIADB_PASSWORD=wordpress
      - MARIADB_DATABASE=wordpress
    volumes:
      - db_data1:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 5

  db2:
    image: mariadb:11
    command: >
      --wsrep-on=ON
      --wsrep-provider=/usr/lib/galera/libgalera_smm.so
      --wsrep-cluster-name=wp_cluster
      --wsrep-cluster-address=gcomm://db,db2,db3
      --wsrep-node-name=db2
      --wsrep-node-address=db2
      --wsrep-sst-method=mariabackup
      --wsrep-sst-auth=root:reas2024
      --binlog-format=ROW
      --default-storage-engine=InnoDB
      --innodb-autoinc-lock-mode=2
    environment:
      - MARIADB_ROOT_PASSWORD=reas2024
    volumes:
      - db_data2:/var/lib/mysql
    depends_on:
      db:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized", "--galera_online"]
      interval: 10s
      timeout: 5s
      retries: 10

  db3:
    image: mariadb:11
    command: >
      --wsrep-on=ON
      --wsrep-provider=/usr/lib/galera/libgalera_smm.so
      --wsrep-cluster-name=wp_cluster
      --wsrep-cluster-address=gcomm://db,db2,db3
      --wsrep-node-name=db3
      --wsrep-node-address=db3
      --wsrep-sst-method=mariabackup
      --wsrep-sst-auth=root:reas2024
      --binlog-format=ROW
      --default-storage-engine=InnoDB
      --innodb-autoinc-lock-mode=2
    environment:
      - MARIADB_ROOT_PASSWORD=reas2024
    volumes:
      - db_data3:/var/lib/mysql
    depends_on:
      db:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized", "--galera_online"]
      interval: 10s
      timeout: 5s
      retries: 10

volumes:
  db_data1:
  db_data2:
  db_data3:
```

Important: `--wsrep-new-cluster` must only be used to *create* the cluster — remove it on restart
of `db` if `db2`/`db3` are still running, or it will create a new cluster UUID instead of rejoining.
Check cluster state with `SHOW GLOBAL STATUS LIKE 'wsrep_%'` (`wsrep_cluster_size` should be 3).

Connect WordPress to each DB node and rerun all tests.

**Security:** don't expose backend services externally — split frontend/backend Docker networks
so e.g. the Nginx container cannot reach the DB cluster directly.

### HTTP/2 and HTTP/3 (bonus)

Enable HTTP/2 and/or HTTP/3 and observe the performance improvement. Requires HTTPS for
QUIC+HTTP/3; a non-standard Docker image may be needed for HTTP/3 support.

### What to include on the report? (Load Balancing / Web Caching chapter)

- Topology diagram showing load generator, Nginx reverse proxy, and backend WordPress containers.
- Configuration snippets for Nginx load balancing and sample WordPress/Docker Compose files.
- Apache JMeter test plans used along with important parameters configured.
- Performance metrics collected from JMeter for different scenarios:
  - Single WordPress container;
  - Multiple WordPress containers;
  - With backend DB in clustering mode;
  - With different Nginx load balancing strategies;
  - With Nginx caching enabled.
- Comparative analysis of performance for different configurations:
  - Requests per second;
  - Average response times;
  - Error percentages;
  - Resource usage on containers.
- Evaluation of different Nginx load balancing algorithms based on performance.
- Analysis of benefits of horizontal scaling and load balancing.
- Recommendations for optimization — number of backend containers, caching settings, etc.
- Discussion of additional features like health checks, SSL termination, sticky sessions.
- Considerations for taking the setup to production — security, reliability, zero downtime updates.

The report should demonstrate proficiency in using tools like JMeter and Nginx for load testing,
characterize and compare performance gains from scaling/load balancing, and provide insight into
real-world deployment considerations.

---

## Container Orchestration With Kubernetes

Docker Compose works well for simple scenarios but becomes challenging for complex distributed
applications: automatic scaling, rolling updates, service discovery, and health checking all require
manual intervention. Kubernetes addresses these limitations with a robust, declarative container
orchestration platform. Key benefits:

- **Automatic scaling** — horizontal/vertical scaling based on resource utilization;
- **Self-healing** — automatic restart/rescheduling of failed containers;
- **Rolling updates** — zero-downtime deployments with automated rollback;
- **Service discovery** — built-in DNS and load balancing between service instances;
- **Resource management** — efficient allocation of CPU/memory/storage across the cluster;
- **Configuration management** — centralized configs/secrets.

We deploy the **Google Online Boutique** application — a cloud-native e-commerce demo with
11 polyglot microservices:

| Service | Language | Role |
|---|---|---|
| Frontend | Go | Web UI, session management |
| Product Catalog Service | Go | Product inventory & search |
| Cart Service | C# | Shopping cart (Redis backend) |
| Currency Service | Node.js | Currency conversion (ECB data) |
| Payment Service | Node.js | Credit card processing simulation |
| Shipping Service | Go | Shipping cost/delivery estimation |
| Checkout Service | Go | Order orchestration |
| Email Service | Python | Order confirmation emails |
| Recommendation Service | Python | Product recommendations |
| Ad Service | Java | Contextual ads |
| Load Generator | Python/Locust | Traffic simulation |

### Setting Up Kubernetes

Use Minikube to run a local cluster. Install `kubectl` and `minikube`, then:

```bash
$ minikube start --driver=docker --cpus=4 --memory=8192
$ kubectl cluster-info
$ kubectl get nodes
$ kubectl get pods -n kube-system
```

### Deploying Google Online Boutique

```bash
$ git clone --depth 1 --branch v0 https://github.com/GoogleCloudPlatform/microservices-demo.git
$ cd microservices-demo/
$ kubectl apply -f ./release/kubernetes-manifests.yaml
$ kubectl get pods
$ kubectl get services
```

Each service's manifest defines a **Deployment** (desired replica state), a **Service** (stable
networking/LB), and optionally a **ConfigMap**/**Secret**.

Before exposing the app, explore the deployment:

1. List all pods and identify which microservice each one runs.
2. Examine `currencyservice`: replica count, resource requests/limits, container image.
3. Examine `frontend` service: type, why that type, alternatives.
4. Check how configuration is specified in the deployment.

```bash
$ minikube service frontend-external --url
```

This URL only works locally to the VM — Minikube doesn't provide a real LoadBalancer, so ports
must be forwarded (or `minikube tunnel` used).

### External Access Configuration (Ingress)

```bash
$ minikube addons enable ingress
```

`boutique-ingress.yaml` (replace `NN` with group number):

```yaml
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
  - host: reas-gNN.dyn.fil.isel.pt
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: frontend
            port:
              number: 80
```

```bash
$ kubectl apply -f boutique-ingress.yaml
$ kubectl describe ingress boutique-ingress
$ kubectl get svc -n ingress-nginx
$ minikube ip   # should be 192.168.49.2

$ sudo iptables -t nat -I PREROUTING 1 -p tcp --dport 80 -j DNAT --to-destination <MINIKUBE_IP>:80
$ sudo iptables -I FORWARD 1 -p tcp -d <MINIKUBE_IP> --dport 80 -j ACCEPT
$ sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
```

Access at `http://reas-gNN.dyn.fil.isel.pt`. Persist iptables rules (careful — this saves *all*
rules, including Minikube's own):

```bash
$ sudo apt install -y iptables-persistent
$ sudo netfilter-persistent save
```

To tear down: `kubectl delete -f ./release/kubernetes-manifests.yaml`.

### Performance Testing and Scaling

Use JMeter (as with WordPress) for user journeys: browse catalogue, add to cart, checkout.
Scenarios: single-replica baseline, horizontal scaling, resource-constrained behavior.

```bash
$ kubectl scale deployment frontend --replicas=3
$ kubectl get pods -l app=frontend
```

Verify/patch `currencyservice` resource requests (mandatory for HPA):

```bash
$ kubectl get deployment currencyservice -o jsonpath='{.spec.template.spec.containers[0].resources}' | jq

$ kubectl patch deployment currencyservice -p '
spec:
  template:
    spec:
      containers:
      - name: server
        resources:
          requests:
            memory: "64Mi"
            cpu: "100m"
          limits:
            memory: "128Mi"
            cpu: "200m"
'
```

### Advanced Kubernetes Features

**Resource monitoring:**

```bash
$ minikube addons enable metrics-server
$ kubectl top nodes
$ kubectl top pods
$ kubectl describe node minikube
$ kubectl get events --sort-by='.lastTimestamp'
$ kubectl top pods -l app=currencyservice
$ kubectl top pods -l app=productcatalogservice
```

**Horizontal Pod Autoscaler (HPA)** for `currencyservice` (highest-QPS service),
`currencyservice-hpa.yaml`:

```yaml
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
```

```bash
$ minikube addons enable metrics-server
$ kubectl apply -f currencyservice-hpa.yaml
$ kubectl get hpa currencyservice-hpa --watch
$ kubectl get pods -l app=currencyservice --watch
$ kubectl top pods -l app=currencyservice
```

**Load testing with the built-in load generator:**

```bash
$ kubectl get pods -l app=loadgenerator
$ kubectl logs deployment/loadgenerator -f
$ kubectl describe deployment loadgenerator
$ kubectl get deployment loadgenerator -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="USERS")].value}'
$ kubectl set env deployment/loadgenerator USERS=200
```

Wait 2–3 minutes for load generator ramp-up (150–200 req/s), metrics collection, and HPA reaction.

Conceptual questions to answer: why are resource requests mandatory for HPA; what "50% CPU
utilization" means in the HPA context; how HPA computes replica counts.

Experiment protocol: USERS=10 → 50 → 100 → 200, observing per level: time for HPA to react,
replicas created, whether scaling stabilized the metrics. Document a timeline (load events → HPA
decisions → CPU trend → replica count over time). Critically analyze: was scaling too
slow/aggressive, did you see flapping, how would you tune HPA, and what is the HPA stabilization
window?

**Health checks and self-healing:**

```bash
$ kubectl describe deployment currencyservice
$ kubectl describe deployment frontend
```

**Rolling updates:**

```bash
$ kubectl get deployment frontend -o jsonpath='{.spec.template.spec.containers[0].image}'
$ kubectl set image deployment/frontend server=us-central1-docker.pkg.dev/google-samples/microservices-demo/frontend:v0.10.2
$ kubectl rollout status deployment/frontend
$ kubectl rollout history deployment/frontend
$ kubectl get pods -l app=frontend --watch
$ kubectl rollout history deployment/frontend --revision=2
$ kubectl rollout undo deployment/frontend
```

Check that revisions always increase.

**Service discovery and networking:**

```bash
$ kubectl exec -it deployment/redis-cart -- nslookup productcatalogservice
$ kubectl describe service productcatalogservice
```

### What to include in the report? (Kubernetes chapter)

- Architecture diagram showing the Kubernetes cluster with all Google Online Boutique
  microservices and their relationships.
- Kubernetes manifests for key services with explanations of Deployments, Services, and resource
  configurations.
- Performance metrics collected from load generator for different scenarios:
  - Baseline performance with default load;
  - Impact of manual scaling on frontend service;
  - HPA scaling behaviour for currencyservice under increased load (USERS=50+);
  - Resource utilization patterns during scaling events.
- Comparative analysis of performance metrics:
  - Requests per second (from load generator output);
  - Average response times;
  - Resource consumption (CPU, memory) per service;
  - Error rates under different load conditions.
- Scaling experiments demonstrating:
  - Manual scaling results for frontend service (1 vs 3 vs 5 replicas);
  - HPA configuration for currencyservice and observed behaviour;
  - Time to scale up/down and stability of autoscaling decisions;
  - Identification of bottleneck services in the architecture.
- Operational capabilities evaluation:
  - Rolling update process with zero-downtime verification;
  - Rollback procedure demonstration;
  - Self-healing behaviour (pod failure and automatic restart);
  - Health check configuration and effectiveness.
- Kubernetes vs Docker Compose comparison highlighting:
  - Deployment complexity and management overhead;
  - Scalability and reliability differences;
  - Operational features (automatic scaling, rolling updates, self-healing);
  - When Kubernetes adoption is justified vs overkill for simpler applications.

The report should demonstrate understanding of container orchestration principles and the
operational advantages Kubernetes provides over Docker Compose deployment.

---

## Service Mesh

As the number of microservices grows, service-to-service communication becomes complex:
service discovery, load balancing, security (encryption/access control), observability, resilience
(retries/timeouts/circuit breakers), and traffic management (canary, A/B testing, traffic splitting).
Kubernetes alone doesn't solve these — a **service mesh** adds a dedicated infrastructure layer:

- **Data plane** — lightweight proxies (Envoy) beside each service instance;
- **Control plane** — centralized management/configuration of the proxies;
- **Configuration APIs** — declarative traffic-policy definitions.

**Istio** is the most popular open-source service mesh, using Envoy as the data plane, integrating
natively with Kubernetes.

### Installing Istio

```bash
$ curl -L https://istio.io/downloadIstio | sh -
$ cd istio-*
$ export PATH=$PWD/bin:$PATH

$ istioctl install --set profile=demo -y
$ kubectl label namespace default istio-injection=enabled

$ kubectl get pods -n istio-system
$ istioctl analyze
```

### Enabling Istio for Online Boutique

```bash
$ kubectl rollout restart deployment
$ kubectl get pods -o wide   # expect 2/2 containers per pod (app + Envoy sidecar)
$ istioctl analyze
```

### Configuring External Access With Istio

Minikube has no cloud LoadBalancer — route external traffic to the Istio IngressGateway's
NodePort instead of the old Nginx ingress:

```bash
$ ISTIO_HTTP_NODEPORT=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')

$ sudo iptables -t nat -D PREROUTING -p tcp --dport 80 -j DNAT --to-destination $(minikube ip):80 2>/dev/null || true
$ kubectl delete ingress boutique-ingress
$ minikube addons disable ingress

$ sudo iptables -t nat -I PREROUTING 1 -p tcp --dport 80 -j DNAT --to-destination $(minikube ip):$ISTIO_HTTP_NODEPORT
$ sudo iptables -I FORWARD 1 -p tcp -d $(minikube ip) --dport $ISTIO_HTTP_NODEPORT -j ACCEPT
$ sudo netfilter-persistent save   # optional
```

### Creating Istio Gateway and VirtualService

`frontend-gateway.yaml`:

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: frontend-gateway
  namespace: default
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "*"
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: frontend
  namespace: default
spec:
  hosts:
  - "*"
  gateways:
  - frontend-gateway
  http:
  - route:
    - destination:
        host: frontend
        port:
          number: 80
```

```bash
$ kubectl apply -f frontend-gateway.yaml
```

Access at `http://reas-gNN.dyn.fil.isel.pt`. Verify traffic through Istio:

```bash
$ kubectl logs -n istio-system deployment/istio-ingressgateway --tail=50
```

### Accessing Observability Tools

Run from inside the Istio install folder:

```bash
$ kubectl apply -f samples/addons/
$ kubectl get pods -n istio-system
```

Installs **Grafana, Prometheus, Jaeger, Kiali**. Wait 2-3 minutes, then expose via NodePort:

```bash
$ kubectl patch svc grafana -n istio-system -p '{"spec":{"type":"NodePort"}}'
$ kubectl patch svc kiali -n istio-system -p '{"spec":{"type":"NodePort"}}'
$ kubectl patch svc tracing -n istio-system -p '{"spec":{"type":"NodePort"}}'
$ kubectl get svc grafana kiali tracing -n istio-system
```

Forward external ports via iptables (Grafana→3000, Kiali→20001, Jaeger→16686):

```bash
$ GRAFANA_NODEPORT=$(kubectl get svc grafana -n istio-system -o jsonpath='{.spec.ports[0].nodePort}')
$ KIALI_NODEPORT=$(kubectl get svc kiali -n istio-system -o jsonpath='{.spec.ports[0].nodePort}')
$ JAEGER_NODEPORT=$(kubectl get svc tracing -n istio-system -o jsonpath='{.spec.ports[0].nodePort}')
$ MINIKUBE_IP=$(minikube ip)

$ sudo iptables -t nat -I PREROUTING 1 -p tcp --dport 3000 -j DNAT --to-destination $MINIKUBE_IP:$GRAFANA_NODEPORT
$ sudo iptables -t nat -I PREROUTING 1 -p tcp --dport 20001 -j DNAT --to-destination $MINIKUBE_IP:$KIALI_NODEPORT
$ sudo iptables -t nat -I PREROUTING 1 -p tcp --dport 16686 -j DNAT --to-destination $MINIKUBE_IP:$JAEGER_NODEPORT

$ sudo iptables -I FORWARD 1 -p tcp -d $MINIKUBE_IP --dport $GRAFANA_NODEPORT -j ACCEPT
$ sudo iptables -I FORWARD 1 -p tcp -d $MINIKUBE_IP --dport $KIALI_NODEPORT -j ACCEPT
$ sudo iptables -I FORWARD 1 -p tcp -d $MINIKUBE_IP --dport $JAEGER_NODEPORT -j ACCEPT
```

Access: `Grafana http://reas-gNN...:3000`, `Kiali http://reas-gNN...:20001`,
`Jaeger http://reas-gNN...:16686`.

**Kiali** — service-mesh topology, traffic flow, config validation, mTLS/security overview
("Versioned app graph", Traffic Distribution, Traffic Animation).

**Grafana** — pre-built Istio dashboards: Service (req rate/latency p50/95/99/success rate),
Workload (CPU/mem/traffic per pod), Performance (control+data plane).

**Jaeger** — needs tracing explicitly enabled (demo profile doesn't register the `jaeger` extension
provider by default):

```bash
$ cat <<EOF > ./tracing.yaml
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
$ istioctl install -f ./tracing.yaml -y

$ kubectl apply -f - <<EOF
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
EOF
```

100% sampling is for the lab only (production: 1–5%).

### Traffic Management

**Load balancing algorithms** — default is round-robin; switch `currencyservice` to
least-request, `currencyservice-lb.yaml`:

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: currencyservice
  namespace: default
spec:
  host: currencyservice
  trafficPolicy:
    loadBalancer:
      simple: LEAST_REQUEST   # LEAST_CONN is deprecated
    connectionPool:
      tcp:
        maxConnections: 100
      http:
        http1MaxPendingRequests: 50
        maxRequestsPerConnection: 2
```

```bash
$ kubectl apply -f currencyservice-lb.yaml
$ kubectl get destinationrule currencyservice -o yaml
$ kubectl set env deployment/loadgenerator USERS=50
$ kubectl logs -l app=currencyservice --tail=5 --prefix
$ kubectl top pods -l app=currencyservice
```

**Traffic splitting for canary deployments** — deploy `frontend-v2` (older tag), split traffic.

```bash
$ kubectl get virtualservice frontend
$ kubectl delete virtualservice frontend   # replaced by two VS below (gateway vs mesh-internal)
$ kubectl get deployment frontend -o jsonpath='{.spec.template.spec.containers[0].image}'
$ kubectl patch deployment frontend -p '{"spec":{"template":{"metadata":{"labels":{"version":"v1"}}}}}'

$ kubectl get deployment frontend -o yaml | \
  sed -e 's/name: frontend/name: frontend-v2/' \
      -e 's/version: v1/version: v2/' \
      -e 's/:v0\.[0-9.]*$/:v0.10.2/' | \
  kubectl apply -f -

$ kubectl get pods -l app=frontend
$ kubectl get endpoints frontend
```

`frontend-destinationrule.yaml`:

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: frontend
  namespace: default
spec:
  host: frontend
  subsets:
  - name: v1
    labels:
      version: v1
  - name: v2
    labels:
      version: v2
```

`frontend-virtualservice.yaml` (split gateway vs internal/mesh traffic, 90/10):

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: frontend-external
  namespace: default
spec:
  hosts:
  - "*"
  gateways:
  - frontend-gateway
  http:
  - route:
    - destination:
        host: frontend
        subset: v1
      weight: 90
    - destination:
        host: frontend
        subset: v2
      weight: 10
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: frontend-mesh
  namespace: default
spec:
  hosts:
  - frontend
  gateways:
  - mesh
  http:
  - route:
    - destination:
        host: frontend
        subset: v1
      weight: 90
    - destination:
        host: frontend
        subset: v2
      weight: 10
```

```bash
$ kubectl apply -f frontend-destinationrule.yaml
$ kubectl apply -f frontend-virtualservice.yaml
```

Verify ~90/10 split in Kiali (Applications → frontend) and Grafana (Service Workload="v1" vs
"v2"). Gradually shift weights to 50/50 then 0/100 via `kubectl edit virtualservice ...`; instant
rollback example:

```bash
$ kubectl patch virtualservice frontend-external --type=json -p='[
  {"op": "replace", "path": "/spec/http/0/route/0/weight", "value": 100},
  {"op": "replace", "path": "/spec/http/0/route/1/weight", "value": 0}
]'
```

### Security Features

**Mutual TLS (mTLS)** — encrypts + mutually authenticates service-to-service traffic.

```bash
$ istioctl proxy-config secret deployment/frontend -o json   # base64 cert data
$ kubectl get peerauthentication -A   # none ⇒ PERMISSIVE by default
```

Explicit STRICT policy:

```bash
$ kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: default
spec:
  mtls:
    mode: STRICT
EOF

$ kubectl exec deployment/productcatalogservice -c istio-proxy -- pilot-agent request GET config_dump | grep '"require_client_certificate"'
```

PromQL (Grafana Explore) to count mTLS connections:

```
sum(istio_tcp_connections_opened_total{reporter="destination",connection_security_policy="mutual_tls"})
```

Key concepts: **PERMISSIVE** (accepts mTLS+plaintext, migration-friendly) vs **STRICT**
(mTLS-only, production-recommended) vs **Auto-mTLS** (auto-upgrade when both sides have
sidecars). In Minikube, unmeshed pods may still succeed due to Service networking quirks — what
matters is that *meshed* service-to-service traffic uses mTLS (verify via Kiali/Prometheus).

**Authorization policies** — fine-grained access control on top of mTLS. Example: only `frontend`
may call `productcatalogservice`:

```bash
$ kubectl create serviceaccount frontend -n default
$ kubectl create serviceaccount productcatalogservice -n default
$ kubectl patch deployment frontend -p '{"spec":{"template":{"spec":{"serviceAccountName":"frontend"}}}}'
$ kubectl patch deployment productcatalogservice -p '{"spec":{"template":{"spec":{"serviceAccountName":"productcatalogservice"}}}}'
```

`productcatalog-authz.yaml`:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: productcatalog-access
  namespace: default
spec:
  selector:
    matchLabels:
      app: productcatalogservice
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/default/sa/frontend"]
    to:
    - operation:
        methods: ["GET", "POST"]
```

```bash
$ kubectl apply -f productcatalog-authz.yaml
$ kubectl describe authorizationpolicy productcatalog-access
$ kubectl delete authorizationpolicy productcatalog-access   # restore open access
```

**Default-deny policy** (demonstration only — breaks the app unless paired with ALLOW rules):

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: default
spec: {}
```

```bash
$ kubectl apply -f deny-all.yaml     # app breaks, Kiali shows red RBAC errors
$ kubectl delete authorizationpolicy deny-all
```

### Fault Injection and Chaos Engineering

**HTTP delay injection** — 5s delay on 50% of `currencyservice` requests,
`currencyservice-delay.yaml`:

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: currencyservice-delay
  namespace: default
spec:
  hosts:
  - currencyservice
  http:
  - fault:
      delay:
        percentage:
          value: 50
        fixedDelay: 5s
    route:
    - destination:
        host: currencyservice
```

```bash
$ kubectl apply -f currencyservice-delay.yaml
$ kubectl logs deployment/frontend -c server --tail=20 -f
```

Grafana: `destination_service="currencyservice.default.svc.cluster.local"` latency p95/p99 spikes
to ~5000ms. Kiali: currencyservice node (and its callers) show increased response time. Jaeger:
slow traces (>5s) show the currencyservice span taking exactly 5s. Remove with
`kubectl delete virtualservice currencyservice-delay`.

**HTTP abort injection** — inject 503s on 30% of mesh-internal `loadgenerator → frontend`
traffic (frontend chosen since it's plain HTTP, unlike the mostly-gRPC backends),
`frontend-abort.yaml`:

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: frontend-mesh
  namespace: default
spec:
  hosts:
  - frontend
  gateways:
  - mesh
  http:
  - fault:
      abort:
        percentage:
          value: 30
        httpStatus: 503
    route:
    - destination:
        host: frontend
```

```bash
$ kubectl apply -f frontend-abort.yaml
$ kubectl logs -l app=loadgenerator --tail=50   # ~30% HTTP 503
```

External browser traffic (via `frontend-external`) is unaffected — only mesh-internal traffic is
targeted. Remove with `kubectl delete virtualservice frontend-mesh` (or reapply without the fault
stanza).

### Circuit Breaker

Prevents cascading failures by detecting an unhealthy service and temporarily stopping requests
to it (states: **Closed** → **Open** → **Half-Open**). Demonstrated on `frontend` (HTTP) even
though the concept applies equally to the mostly-gRPC backend services.

**Enable circuit-breaker statistics** (disabled by default to save CPU/memory):

```bash
$ kubectl annotate deployment loadgenerator \
  proxy.istio.io/config='proxyStatsMatcher:
  inclusionRegexps:
  - ".*outlier_detection.*"
  - ".*upstream_rq_retry.*"
  - ".*upstream_cx_.*"
  inclusionSuffixes:
  - "upstream_rq_timeout"
  - "upstream_rq_pending_overflow"' \
  --overwrite

$ kubectl annotate deployment frontend \
  proxy.istio.io/config='proxyStatsMatcher: ...(same as above)' \
  --overwrite

$ kubectl rollout restart deployment loadgenerator frontend
$ kubectl rollout status deployment loadgenerator
$ kubectl rollout status deployment frontend

$ kubectl exec deployment/loadgenerator -c istio-proxy -- curl -s http://localhost:15090/stats/prometheus | grep outlier
```

Key metrics: `envoy_cluster_outlier_detection_ejections_active`,
`..._ejections_enforced_total`, `..._ejections_enforced_consecutive_gateway_failure`,
`envoy_cluster_upstream_rq_pending_overflow`.

Alternative (global, heavier): edit the `istio` ConfigMap's `defaultConfig.proxyStatsMatcher` in
`istio-system` and restart `istiod` + all deployments. Per-deployment annotations are
recommended for learning/testing.

**Configure the circuit breaker** — baseline first:

```bash
$ kubectl scale deployment frontend --replicas=3
$ kubectl set env deployment/loadgenerator USERS=30
```

`frontend-circuitbreaker.yaml` (deliberately aggressive, for demo purposes):

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: frontend-circuit-breaker
  namespace: default
spec:
  host: frontend
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 1
      http:
        http1MaxPendingRequests: 1
        http2MaxRequests: 1
        maxRequestsPerConnection: 1
    outlierDetection:
      consecutive5xxErrors: 1
      consecutiveGatewayErrors: 1
      interval: 1s
      baseEjectionTime: 180s
      maxEjectionPercent: 100
      minHealthPercent: 0
```

```bash
$ kubectl apply -f frontend-circuitbreaker.yaml
$ kubectl exec deployment/frontend -c istio-proxy -- pilot-agent request GET config_dump | grep -A 20 "outlier_detection"
```

**Trigger it** by starving `frontend` of resources and raising load:

```bash
$ kubectl patch deployment frontend --type='json' -p='[
  {"op": "add", "path": "/spec/template/spec/containers/0/resources",
   "value": {"requests": {"cpu": "5m", "memory": "20Mi"},
             "limits":   {"cpu": "10m", "memory": "30Mi"}}}
]'
$ kubectl set env deployment/loadgenerator USERS=200
```

**Monitor:**

```bash
$ kubectl exec deployment/loadgenerator -c istio-proxy -- curl -s http://localhost:15090/stats/prometheus | grep "pending_overflow"
$ kubectl exec deployment/loadgenerator -c istio-proxy -- curl -s http://localhost:15090/stats/prometheus | grep "ejections"
$ kubectl exec deployment/loadgenerator -c istio-proxy -- curl -s http://localhost:15000/clusters | grep "outbound|80||frontend" | grep "health_flags"
```

Healthy endpoints: `health_flags::healthy`; ejected: `health_flags::/failed_outlier_check`.

Grafana PromQL (Explore):

```
envoy_cluster_outlier_detection_ejections_active{cluster_name=~".*frontend.*"}
sum(envoy_cluster_outlier_detection_ejections_enforced_total{cluster_name=~".*frontend.*"})
rate(envoy_cluster_upstream_rq_pending_overflow{cluster_name=~".*frontend.*"}[1m])
envoy_cluster_outlier_detection_ejections_enforced_consecutive_gateway_failure{cluster_name=~".*frontend.*"}
```

**Minikube caveat:** single-node, low-latency, fast failure detection/recovery, and the scheduler's
own resource-pressure throttling all make ejections look smaller/rarer than in production — this
doesn't mean the circuit breaker isn't working, just that recovery (within `baseEjectionTime`) is
fast in this environment.

**Cleanup:**

```bash
$ kubectl delete virtualservice --all
$ kubectl delete destinationrule --all
$ kubectl set env deployment/loadgenerator USERS=30
$ kubectl apply -f frontend-gateway.yaml   # restore external access (VS was deleted above)
$ kubectl scale deployment frontend --replicas=3
$ kubectl patch deployment frontend --type=json -p='[{"op":"remove","path":"/spec/template/spec/containers/0/resources"}]'
```

### Performance Analysis

Assess Istio's performance overhead across several axes.

**Baseline** (sidecars injected, mTLS PERMISSIVE):

```bash
$ kubectl top pods --sort-by=memory > baseline-resources.txt
$ kubectl top nodes > baseline-nodes.txt
```

Grafana PromQL (Explore), against `frontend.default.svc.cluster.local`:

```
sum(rate(istio_requests_total{destination_service="frontend.default.svc.cluster.local"}[1m]))
histogram_quantile(0.50, sum(rate(istio_request_duration_milliseconds_bucket{destination_service="frontend.default.svc.cluster.local"}[1m])) by (le))
histogram_quantile(0.95, ...)
histogram_quantile(0.99, ...)
```

Record: Frontend req/s, P50/P95/P99 latency, total cluster CPU/Memory.

**Sidecar proxy overhead** — `kubectl top pods --containers` to compare `server` vs
`istio-proxy` CPU/memory per pod; for lightweight services (e.g. currencyservice) the sidecar can
dominate the pod's footprint; for heavier services it's proportionally smaller.

**mTLS performance impact** — switch PERMISSIVE → STRICT (same `PeerAuthentication` as the
Security section), wait 2-3 min, re-measure. Expected: P50 +1-3ms, P95 +3-5ms (TLS handshake),
CPU +5-10% (crypto), memory +<5%. Table: `Configuration | P50 | P95 | CPU | Memory | Overhead %` for PERMISSIVE vs STRICT.

**Traffic-management overhead** — apply increasingly complex `VirtualService`/`DestinationRule`
configs and re-measure each time: plain routing (`frontend-simple.yaml`), traffic
splitting/header-matching (`frontend-canary.yaml`), + circuit breaker
(`frontend-with-cb.yaml`), then LB algorithm comparison
(`frontend-lb-rr.yaml`/`frontend-lb-lc.yaml`/`frontend-lb-random.yaml` — ROUND_ROBIN /
LEAST_REQUEST / RANDOM). Expected magnitudes: simple routing ~baseline, canary/header-match
~10-15% overhead, circuit breaker ~negligible (passive monitoring), LEAST_REQUEST
+0.1-0.3ms vs ROUND_ROBIN, RANDOM -0.1-0.2ms (cheapest, no state). Fill in:

| Configuration | P50 (ms) | P95 (ms) | P99 (ms) | Req/s | Overhead vs Baseline |
|---|---|---|---|---|---|
| Baseline (no rules) | | | | | 0% |
| Simple routing | | | | | |
| Traffic splitting | | | | | |
| With circuit breaker | | | | | |
| Round-robin LB | | | | | |
| Least request LB | | | | | |
| Random LB | | | | | |

Be critical: Minikube runs inside a shared lab VM, adding measurement noise.

**Control plane resource usage:** `kubectl top pods -n istio-system`.

**Latency breakdown via Jaeger:** generate load (`USERS=50`), inspect a multi-service trace
(e.g. checkout) in Jaeger, identify where Istio/Envoy adds latency vs application processing.

### What to include in the report? (Service Mesh chapter)

- Service mesh architecture diagram showing Istio components (istiod, ingress gateway, Envoy
  sidecars) and their integration with Online Boutique services.
- Installation and configuration process documenting:
  - Istio installation on Minikube with external access setup;
  - Sidecar injection verification;
  - Gateway and VirtualService configuration;
  - Observability tools deployment and access.
- Traffic management demonstrations:
  - Load balancing algorithm comparison (round-robin vs least connections);
  - Circuit breaker configuration and failure simulation results;
  - Canary deployment with traffic splitting (90/10, 50/50);
  - Screenshots from Kiali showing traffic distribution.
- Security implementation analysis:
  - mTLS configuration and verification;
  - Authorization policy testing (allow/deny rules);
  - Comparison of mTLS modes (PERMISSIVE vs STRICT);
  - Evidence of encrypted service-to-service communication.
- Observability capabilities evaluation:
  - Distributed tracing examples from Jaeger showing multi-service requests;
  - Service dependency graph from Kiali;
  - Performance metrics from Grafana dashboards;
  - Analysis of how these tools aid debugging and monitoring.
- Fault injection experiments:
  - Delay injection results and application behavior;
  - Error injection (abort) impact on user experience;
  - Cascading failure demonstration;
  - Evidence from Kiali/Grafana showing injected faults.
- Performance impact assessment:
  - Sidecar resource overhead measurements (memory, CPU);
  - mTLS latency overhead comparison;
  - Control plane resource consumption;
  - Distributed tracing latency analysis;
  - Total Istio overhead calculation.
- Critical analysis:
  - When is service mesh adoption justified vs overkill?
  - Complexity vs benefits trade-off;
  - Minikube limitations vs production Istio deployments;
  - Operational learning curve and team readiness considerations.

The report should demonstrate comprehensive understanding of service mesh architecture and
practical experience with Istio's traffic management, security, and observability features, and
should articulate both the benefits and costs of adopting a service mesh for microservices
architectures.

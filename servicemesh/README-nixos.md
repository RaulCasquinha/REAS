# Service Mesh (Istio) Lab — NixOS Guide

Enter the shell to get `minikube`, `kubectl`, `istioctl`, `jq`, and `iptables` from nixpkgs:

```bash
nix-shell
```

All commands below run inside that shell — no `steam-run` needed.

## Prerequisites

- The Kubernetes lab (`kuber/run-lab.sh`, sections 1-2) already run: a minikube cluster with
  Google Online Boutique deployed in the `default` namespace.
- `istioctl` from nix-shell only ships the CLI — the `samples/addons/` manifests (Grafana,
  Prometheus, Jaeger, Kiali) live in the full Istio release tarball, so step 4 below still needs
  `curl -L https://istio.io/downloadIstio | sh -` once to fetch them.

---

## 1. Install Istio

```bash
istioctl install --set profile=demo -y
kubectl label namespace default istio-injection=enabled
kubectl get pods -n istio-system
istioctl analyze
```

---

## 2. Enable sidecar injection for Online Boutique

```bash
kubectl rollout restart deployment
kubectl get pods -o wide   # expect 2/2 containers per pod (app + istio-proxy)
istioctl analyze
```

---

## 3. External access via Istio Gateway

```bash
kubectl apply -f frontend-gateway.yaml
```

If the Kubernetes lab's Nginx ingress is still forwarding port 80, remove it first:

```bash
sudo iptables -t nat -D PREROUTING -p tcp --dport 80 -j DNAT --to-destination $(minikube ip):80
kubectl delete ingress boutique-ingress
minikube addons disable ingress
```

Forward external port 80 to the Istio ingress gateway's NodePort instead:

```bash
ISTIO_HTTP_NODEPORT=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')
sudo iptables -t nat -I PREROUTING 1 -p tcp --dport 80 -j DNAT --to-destination $(minikube ip):$ISTIO_HTTP_NODEPORT
sudo iptables -I FORWARD 1 -p tcp -d $(minikube ip) --dport $ISTIO_HTTP_NODEPORT -j ACCEPT
```

To persist iptables rules on NixOS, add to `configuration.nix` (mirroring the Kubernetes lab's
`README-nixos.md`):

```nix
networking.firewall.enable = false;
networking.nftables.enable = false;
boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

networking.localCommands = ''
  iptables -t nat -I PREROUTING 1 -p tcp --dport 80 -j DNAT --to-destination 192.168.49.2:<ISTIO_HTTP_NODEPORT>
  iptables -I FORWARD 1 -p tcp -d 192.168.49.2 --dport <ISTIO_HTTP_NODEPORT> -j ACCEPT
'';
```

Then `sudo nixos-rebuild switch`. Access the shop at `http://reas-gNN.dyn.fil.isel.pt`.

Verify traffic is flowing through Istio:

```bash
kubectl logs -n istio-system deployment/istio-ingressgateway --tail=50
```

---

## 4. Observability addons (Grafana, Prometheus, Jaeger, Kiali)

Fetch the full Istio release once (for `samples/addons/`, not shipped by the nixpkgs `istioctl`
package):

```bash
curl -L https://istio.io/downloadIstio | sh -
kubectl apply -f istio-*/samples/addons/
kubectl get pods -n istio-system
```

Expose via NodePort and forward:

```bash
kubectl patch svc grafana -n istio-system -p '{"spec":{"type":"NodePort"}}'
kubectl patch svc kiali -n istio-system -p '{"spec":{"type":"NodePort"}}'
kubectl patch svc tracing -n istio-system -p '{"spec":{"type":"NodePort"}}'

GRAFANA_NODEPORT=$(kubectl get svc grafana -n istio-system -o jsonpath='{.spec.ports[0].nodePort}')
KIALI_NODEPORT=$(kubectl get svc kiali -n istio-system -o jsonpath='{.spec.ports[0].nodePort}')
JAEGER_NODEPORT=$(kubectl get svc tracing -n istio-system -o jsonpath='{.spec.ports[0].nodePort}')
MINIKUBE_IP=$(minikube ip)

sudo iptables -t nat -I PREROUTING 1 -p tcp --dport 3000 -j DNAT --to-destination $MINIKUBE_IP:$GRAFANA_NODEPORT
sudo iptables -t nat -I PREROUTING 1 -p tcp --dport 20001 -j DNAT --to-destination $MINIKUBE_IP:$KIALI_NODEPORT
sudo iptables -t nat -I PREROUTING 1 -p tcp --dport 16686 -j DNAT --to-destination $MINIKUBE_IP:$JAEGER_NODEPORT
sudo iptables -I FORWARD 1 -p tcp -d $MINIKUBE_IP --dport $GRAFANA_NODEPORT -j ACCEPT
sudo iptables -I FORWARD 1 -p tcp -d $MINIKUBE_IP --dport $KIALI_NODEPORT -j ACCEPT
sudo iptables -I FORWARD 1 -p tcp -d $MINIKUBE_IP --dport $JAEGER_NODEPORT -j ACCEPT
```

- Grafana: `http://reas-gNN.dyn.fil.isel.pt:3000`
- Kiali: `http://reas-gNN.dyn.fil.isel.pt:20001`
- Jaeger: `http://reas-gNN.dyn.fil.isel.pt:16686`

Register the `jaeger` tracing extension provider (demo profile doesn't ship it):

```bash
cat <<EOF > ./tracing.yaml
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
istioctl install -f ./tracing.yaml -y

kubectl apply -f - <<EOF
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

---

## 5. Traffic management

```bash
kubectl apply -f currencyservice-lb.yaml
kubectl get destinationrule currencyservice -o yaml
kubectl set env deployment/loadgenerator USERS=50
kubectl top pods -l app=currencyservice
```

Canary (90/10 → 50/50 → 100/0) — see `docs/work/work_instructions.md` for
`frontend-destinationrule.yaml` / `frontend-virtualservice.yaml`.

---

## 6. Security — mTLS and authorization policies

```bash
kubectl get peerauthentication -A

kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: default
spec:
  mtls:
    mode: STRICT
EOF

kubectl exec deployment/productcatalogservice -c istio-proxy -- pilot-agent request GET config_dump | grep '"require_client_certificate"'
```

Authorization policy manifests: see `docs/work/work_instructions.md`.

---

## 7. Fault injection and circuit breaker

Delay/abort injection and the aggressive `frontend` circuit breaker — manifests in
`docs/work/work_instructions.md`. Monitor with:

```bash
kubectl exec deployment/loadgenerator -c istio-proxy -- curl -s http://localhost:15090/stats/prometheus | grep ejections
```

---

## 8. Performance overhead

```bash
kubectl top pods --containers
kubectl top pods -n istio-system
```

Grafana PromQL — see `README.md` §8.

---

## Cleanup

```bash
kubectl delete virtualservice --all
kubectl delete destinationrule --all
kubectl delete authorizationpolicy --all
kubectl label namespace default istio-injection-
kubectl rollout restart deployment
istioctl uninstall --purge -y
```

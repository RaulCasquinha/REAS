# Kubernetes Lab — NixOS Guide

Enter the shell to get `minikube`, `kubectl`, `jq`, and `iptables` from nixpkgs:

```bash
nix-shell
```

All commands below run inside that shell — no `steam-run` needed.

---

## 1. Start the cluster

```bash
minikube start --driver=docker --cpus=4 --memory=8192
```

Verify it's running:

```bash
kubectl cluster-info
kubectl get nodes
kubectl get pods -n kube-system
```

---

## 2. Deploy Google Online Boutique

```bash
git clone --depth 1 --branch v0 https://github.com/GoogleCloudPlatform/microservices-demo.git
cd microservices-demo/
kubectl apply -f ./release/kubernetes-manifests.yaml
```

Monitor deployment:

```bash
kubectl get pods
kubectl get services
```

Check application URL (local only):

```bash
minikube service frontend-external --url
```

---

## 3. External access via Ingress

Enable the ingress addon:

```bash
minikube addons enable ingress
```

Create `boutique-ingress.yaml` (replace `NN` with your group number):

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

Apply it:

```bash
kubectl apply -f boutique-ingress.yaml
kubectl describe ingress boutique-ingress
kubectl get svc -n ingress-nginx
```

Get minikube IP and forward traffic:

```bash
minikube ip  # should be 192.168.49.2
```

```bash
sudo iptables -t nat -I PREROUTING 1 -p tcp --dport 80 -j DNAT --to-destination <MINIKUBE_IP>:80
sudo iptables -I FORWARD 1 -p tcp -d <MINIKUBE_IP> --dport 80 -j ACCEPT
sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
```

To persist these rules across reboots, add this to your NixOS `configuration.nix`:

```nix
networking.firewall.enable = false;  # if using iptables directly
networking.nftables.enable = false;

boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

networking.localCommands = ''
  iptables -t nat -I PREROUTING 1 -p tcp --dport 80 -j DNAT --to-destination 192.168.49.2:80
  iptables -I FORWARD 1 -p tcp -d 192.168.49.2 --dport 80 -j ACCEPT
'';
```

Then `sudo nixos-rebuild switch`.

Access the shop at `http://reas-gNN.dyn.fil.isel.pt`.

---

## 4. Resource monitoring

Enable metrics server:

```bash
minikube addons enable metrics-server
```

```bash
kubectl top nodes
kubectl top pods
kubectl describe node minikube
kubectl get events --sort-by='.lastTimestamp'
kubectl top pods -l app=currencyservice
kubectl top pods -l app=productcatalogservice
```

---

## 5. Manual scaling

```bash
kubectl scale deployment frontend --replicas=3
kubectl get pods -l app=frontend
```

---

## 6. Horizontal Pod Autoscaler (HPA)

Verify currencyservice has resource requests:

```bash
kubectl get deployment currencyservice -o jsonpath='{.spec.template.spec.containers[0].resources}' | jq
```

If missing, apply them:

```bash
kubectl patch deployment currencyservice -p '
{
  "spec": {
    "template": {
      "spec": {
        "containers": [{
          "name": "server",
          "resources": {
            "requests": {"memory": "64Mi", "cpu": "100m"},
            "limits": {"memory": "128Mi", "cpu": "200m"}
          }
        }]
      }
    }
  }
}'
```

Create `currencyservice-hpa.yaml`:

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

Apply:

```bash
kubectl apply -f currencyservice-hpa.yaml
```

---

## 7. Load testing with built-in load generator

Check status:

```bash
kubectl get pods -l app=loadgenerator
kubectl logs deployment/loadgenerator -f
kubectl get deployment loadgenerator -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="USERS")].value}'
```

Increase load gradually:

```bash
kubectl set env deployment/loadgenerator USERS=10
kubectl set env deployment/loadgenerator USERS=50
kubectl set env deployment/loadgenerator USERS=100
kubectl set env deployment/loadgenerator USERS=200
```

Monitor scaling in three terminals:

```bash
# Terminal 1
kubectl get hpa currencyservice-hpa --watch

# Terminal 2
kubectl get pods -l app=currencyservice --watch

# Terminal 3
kubectl top pods -l app=currencyservice
```

---

## 8. Rolling updates

Check current image:

```bash
kubectl get deployment frontend -o jsonpath='{.spec.template.spec.containers[0].image}'
```

Roll back to a previous version:

```bash
kubectl set image deployment/frontend server=us-central1-docker.pkg.dev/google-samples/microservices-demo/frontend:v0.10.2
kubectl rollout status deployment/frontend
kubectl rollout history deployment/frontend
kubectl get pods -l app=frontend --watch
```

View a specific revision:

```bash
kubectl rollout history deployment/frontend --revision=2
```

Undo if needed:

```bash
kubectl rollout undo deployment/frontend
```

---

## 9. Service discovery

```bash
kubectl exec -it deployment/redis-cart -- nslookup productcatalogservice
kubectl describe service productcatalogservice
```

---

## 10. Health checks

```bash
kubectl describe deployment currencyservice
kubectl describe deployment frontend
```

---

## Cleanup

```bash
kubectl delete -f ./release/kubernetes-manifests.yaml
```

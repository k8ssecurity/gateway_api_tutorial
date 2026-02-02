# Kubernetes Gateway API Lab

A hands-on lab environment for learning the Kubernetes Gateway API.

**Target Audience:** Network engineers with Linux/Docker experience but limited Kubernetes knowledge.

## What You'll Learn

- How Gateway API provides a standard way to manage ingress traffic
- The relationship between GatewayClass, Gateway, and HTTPRoute resources
- How to configure HTTP and HTTPS listeners
- Traffic splitting (canary deployments)
- Header-based routing

## Network Analogies

| Gateway API Concept | Traditional Networking Equivalent |
|---------------------|-----------------------------------|
| GatewayClass | Load balancer vendor/model (F5, NetScaler, HAProxy) |
| Gateway | Virtual server / VIP with listeners |
| HTTPRoute | L7 routing policy / traffic rules |
| Service | Server pool / backend group |
| Pod | Individual server in the pool |

## Quick Start

```bash
# 1. Make scripts executable
chmod +x setup.sh cleanup.sh

# 2. Run automated setup (takes 5-10 minutes)
./setup.sh

# 3. Test HTTP
curl http://webapp.local.dev/

# 4. Test HTTPS (self-signed cert)
curl -k https://webapp.local.dev/

# 5. When done, clean up
./cleanup.sh
```

## Prerequisites

Before running, install these tools:

| Tool | Purpose | Install (macOS) |
|------|---------|-----------------|
| Docker | Container runtime | `brew install --cask docker` |
| kubectl | Kubernetes CLI | `brew install kubectl` |
| kind | K8s in Docker | `brew install kind` |
| helm | K8s package manager | `brew install helm` |
| cilium | Cilium CLI | `brew install cilium-cli` |

## Component Versions (February 2026)

| Component | Version | Notes |
|-----------|---------|-------|
| Gateway API | v1.4.1 | Experimental channel (includes TLSRoute) |
| Envoy Gateway | v1.6.3 | Latest stable |
| Cilium | v1.18.6 | eBPF-based CNI |
| MetalLB | v0.15.3 | LoadBalancer for bare metal |

**Linux users:** See the main tutorial for installation commands.

## Lab Files

| File | Description |
|------|-------------|
| `01-kind-config.yaml` | Cluster config: 3 nodes (1 control-plane + 2 workers) |
| `02-metallb-config.yaml` | IP pool for LoadBalancer services |
| `03-gateway.yaml` | Gateway with HTTP (80) and HTTPS (443) listeners |
| `04-webapp.yaml` | Sample web application (stable version) |
| `05-webapp-canary.yaml` | Canary version for testing deployments |
| `06-httproute-basic.yaml` | Basic routing: all traffic → stable |
| `07-httproute-canary.yaml` | Traffic splitting: 90% stable, 10% canary |
| `08-httproute-header.yaml` | Header-based routing: X-Canary: true → canary |
| `09-tlsroute-passthrough.yaml` | TLS passthrough routing (SNI-based) |
| `setup.sh` | Automated setup script |
| `cleanup.sh` | Cleanup script |

## Manual Setup (Step by Step)

If you prefer to understand each step:

```bash
# 1. Create the cluster (3 Docker containers as K8s nodes)
kind create cluster --config=01-kind-config.yaml

# 2. Install Cilium (pod networking)
cilium install --version 1.18.6 --set kubeProxyReplacement=true
cilium status --wait

# 3. Install MetalLB (provides external IPs)
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.3/config/manifests/metallb-native.yaml
kubectl wait -n metallb-system --for=condition=ready pod --selector=app=metallb --timeout=120s
kubectl apply -f 02-metallb-config.yaml

# 4. Install Gateway API CRDs - EXPERIMENTAL channel (includes TLSRoute)
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/experimental-install.yaml

# 5. Install Envoy Gateway (the controller)
helm install eg oci://docker.io/envoyproxy/gateway-helm \
    --version v1.6.3 \
    -n envoy-gateway-system \
    --create-namespace \
    --skip-crds

# 6. Create GatewayClass
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
EOF

# 7. Create TLS certificate (BEFORE creating Gateway!)
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /tmp/tls.key -out /tmp/tls.crt \
    -subj "/CN=*.local.dev" \
    -addext "subjectAltName=DNS:*.local.dev,DNS:localhost"
kubectl create secret tls eg-tls-cert \
    --cert=/tmp/tls.crt --key=/tmp/tls.key \
    -n envoy-gateway-system

# 8. Deploy Gateway
kubectl apply -f 03-gateway.yaml
kubectl wait -n envoy-gateway-system gateway/eg-gateway --for=condition=Programmed --timeout=5m

# 9. Deploy application
kubectl apply -f 04-webapp.yaml
kubectl apply -f 05-webapp-canary.yaml

# 10. Deploy HTTPRoute
kubectl apply -f 06-httproute-basic.yaml

# 11. Get Gateway IP and test
GATEWAY_IP=$(kubectl get gateway/eg-gateway -n envoy-gateway-system -o jsonpath='{.status.addresses[0].value}')
curl -H "Host: webapp.local.dev" http://$GATEWAY_IP/
```

## Testing Advanced Routing

### Traffic Splitting (Canary Deployment)

```bash
# Apply canary route (90% stable, 10% canary)
kubectl apply -f 07-httproute-canary.yaml

# Test multiple times to see distribution
for i in {1..20}; do curl -s http://webapp.local.dev/; done
```

### Header-Based Routing

```bash
# Apply header-based route
kubectl apply -f 08-httproute-header.yaml

# Normal request → goes to stable
curl http://webapp.local.dev/

# With header → goes to canary
curl -H "X-Canary: true" http://webapp.local.dev/
```

### TLS Passthrough (TLSRoute)

TLSRoute enables routing encrypted traffic without terminating TLS at the Gateway. The Gateway routes based on SNI (Server Name Indication) only.

```bash
# Apply TLSRoute (requires backend with TLS server)
kubectl apply -f 09-tlsroute-passthrough.yaml

# Key difference from HTTPRoute:
# - HTTPRoute + TLS: Gateway decrypts → inspects HTTP → re-encrypts
# - TLSRoute: Gateway forwards encrypted traffic based on SNI only
```

**When to use TLSRoute:**
- End-to-end encryption requirements (compliance)
- Backend manages its own certificates
- mTLS between client and backend
- Performance (avoid double TLS termination)

## Troubleshooting

### Nodes Stuck in NotReady

```bash
# Check Cilium status
cilium status
kubectl get pods -n kube-system -l k8s-app=cilium
kubectl logs -n kube-system -l k8s-app=cilium
```

### Gateway Has No External IP

```bash
# Check MetalLB
kubectl get pods -n metallb-system
kubectl get ipaddresspools -n metallb-system

# Verify IP range matches Docker network
docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}'
```

### HTTPS Not Working

```bash
# Check Gateway status
kubectl describe gateway eg-gateway -n envoy-gateway-system

# Verify TLS secret exists
kubectl get secret eg-tls-cert -n envoy-gateway-system

# Check for certificate errors in logs
kubectl logs -n envoy-gateway-system deployment/envoy-gateway
```

### HTTPRoute Not Working

```bash
# Check route status
kubectl describe httproute -n demo-app

# Verify route is attached to Gateway
kubectl get httproute -A -o wide
```

## Useful Commands

```bash
# View all Gateway API resources
kubectl get gatewayclass,gateway,httproute -A

# View Gateway details
kubectl describe gateway eg-gateway -n envoy-gateway-system

# View application pods
kubectl get pods -n demo-app -o wide

# View Envoy Gateway logs
kubectl logs -n envoy-gateway-system deployment/envoy-gateway

# Check Service endpoints
kubectl get endpoints -n demo-app
```

---

*Created on a Saturday morning with the help of Claude Cowork and the relentless effort of Philippe Bogaerts for guiding, testing, and troubleshooting. Because nothing says "weekend fun" like debugging x509 certificate errors.* 🎉

# Agentgateway Setup on KIND (with MetalLB)

This doc installs the agentgateway control plane, creates an agentgateway proxy (Gateway API `Gateway`), and wires up an MCP server through the gateway.

---

## What is Agentgateway?

**Agentgateway is a SEPARATE gateway from Envoy Gateway.** It's specifically designed for AI agent communications.

| Aspect | Envoy Gateway | Agentgateway |
|--------|---------------|--------------|
| **Purpose** | Traditional API traffic (HTTP, gRPC, TCP) | AI agent traffic (MCP, A2A protocols) |
| **Data Plane** | Envoy Proxy (C++) | Agentgateway (Rust) |
| **Use Cases** | Web apps, microservices, ingress | LLM tools, MCP servers, agent-to-agent |
| **GatewayClass** | `eg` (Envoy Gateway) | `agentgateway` |
| **Control Plane** | Envoy Gateway controller | kgateway controller |

### Key Concepts

| Term | Description |
|------|-------------|
| **MCP** | Model Context Protocol - standardizes how LLMs connect to external tools |
| **A2A** | Agent-to-Agent protocol - enables AI agents to communicate |
| **kgateway** | Dual control plane for both Envoy and Agentgateway |
| **AgentgatewayBackend** | Custom resource defining MCP server targets |
| **AgentgatewayPolicy** | Tool-level allow/deny rules (CEL expressions) |

### When to Use Which?

- **Envoy Gateway**: Web applications, REST APIs, microservices, traditional L7 routing
- **Agentgateway**: LLM tool servers, MCP integrations, AI agent orchestration, tool access control

You can run **both** in the same cluster - they use different GatewayClasses and don't conflict.

---

## Prerequisites

This guide assumes you already have:
- A working KIND cluster (from the Gateway API tutorial)
- MetalLB installed and configured (so `LoadBalancer` Services get an IP)
- `kubectl` and `helm` installed

---

## 1) Install Gateway API CRDs

If you already did this in the Gateway API tutorial in this repo, you can skip.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml
```

Optional (only if you need experimental Gateway API features later):
```bash
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/experimental-install.yaml
```

---

## 2) Install agentgateway (control plane)

Pick a version and reuse it consistently.

### Version Options (February 2026)

| Version | Channel | Status |
|---------|---------|--------|
| `v2.1.x` | Stable | Production-ready, first version with agentgateway integration |
| `v2.2.0-main` | Development | Latest features, may have breaking changes |
| `v2.2.0-rc.x` | Release Candidate | Pre-release testing |

```bash
# Development version (latest features)
export AGW_VERSION=v2.2.0-main

# Or use the stable version for production:
# export AGW_VERSION=v2.1.0
```

Install the agentgateway CRDs:
```bash
helm upgrade -i agentgateway-crds oci://ghcr.io/kgateway-dev/charts/agentgateway-crds \
  --create-namespace --namespace agentgateway-system \
  --version "${AGW_VERSION}" \
  --set controller.image.pullPolicy=Always
```

Install the agentgateway control plane:
```bash
helm upgrade -i agentgateway oci://ghcr.io/kgateway-dev/charts/agentgateway \
  --namespace agentgateway-system \
  --version "${AGW_VERSION}" \
  --set controller.image.pullPolicy=Always
```

Verify:
```bash
kubectl get pods -n agentgateway-system
```

---

## 3) Create an agentgateway proxy (Gateway)

This creates:
- a `Gateway` named `agentgateway-proxy`
- a `Deployment` and `Service` also named `agentgateway-proxy` in `agentgateway-system`

```bash
kubectl apply -f- <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agentgateway-proxy
  namespace: agentgateway-system
spec:
  gatewayClassName: agentgateway
  listeners:
  - protocol: HTTP
    port: 80
    name: http
    allowedRoutes:
      namespaces:
        from: All
EOF
```

Check status:
```bash
kubectl get gateway agentgateway-proxy -n agentgateway-system
kubectl get deployment agentgateway-proxy -n agentgateway-system
kubectl get svc agentgateway-proxy -n agentgateway-system
```

### Access method A: Use MetalLB EXTERNAL-IP
If the Service gets an EXTERNAL-IP, you can use it directly:
```bash
kubectl get svc -n agentgateway-system agentgateway-proxy
```

### Access method B: Port-forward (always works for local testing)
```bash
kubectl port-forward deployment/agentgateway-proxy -n agentgateway-system 8080:80
```

---

## 4) Option A: Route to a local MCP server (static MCP)

### 4.1 Deploy a sample MCP server (website fetcher)

```bash
kubectl apply -f- <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mcp-website-fetcher
spec:
  selector:
    matchLabels:
      app: mcp-website-fetcher
  template:
    metadata:
      labels:
        app: mcp-website-fetcher
    spec:
      containers:
      - name: mcp-website-fetcher
        image: ghcr.io/peterj/mcp-website-fetcher:main
        imagePullPolicy: Always
---
apiVersion: v1
kind: Service
metadata:
  name: mcp-website-fetcher
  labels:
    app: mcp-website-fetcher
spec:
  selector:
    app: mcp-website-fetcher
  ports:
  - port: 80
    targetPort: 8000
    appProtocol: kgateway.dev/mcp
EOF
```

### 4.2 Create an AgentgatewayBackend

```bash
kubectl apply -f- <<'EOF'
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: mcp-backend
spec:
  mcp:
    targets:
    - name: mcp-target
      static:
        host: mcp-website-fetcher.default.svc.cluster.local
        port: 80
        protocol: SSE
EOF
```

### 4.3 Create an HTTPRoute to the MCP backend

```bash
kubectl apply -f- <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mcp
spec:
  parentRefs:
    - name: agentgateway-proxy
      namespace: agentgateway-system
  rules:
    - backendRefs:
      - name: mcp-backend
        group: agentgateway.dev
        kind: AgentgatewayBackend
EOF
```

### 4.4 Verify with MCP Inspector

In another terminal, keep port-forward running:
```bash
kubectl port-forward deployment/agentgateway-proxy -n agentgateway-system 8080:80
```

Run MCP Inspector:
```bash
npx modelcontextprotocol/inspector#0.18.0
```

Connect:
- Transport Type: Streamable HTTP
- URL: `http://localhost:8080/mcp`

---

## 5) Option B: Route to the remote GitHub MCP server via HTTPS (multi-tool server)

This is useful to see many tools and then test allow/deny rules.

### 5.1 Create a GitHub Personal Access Token
Create a PAT and export it:

```bash
export GH_PAT="<your-personal-access-token>"
```

### 5.2 Create an AgentgatewayBackend for GitHub MCP

```bash
kubectl apply -f- <<'EOF'
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: github-mcp-backend
  namespace: agentgateway-system
spec:
  mcp:
    targets:
    - name: mcp-target
      static:
        host: api.githubcopilot.com
        port: 443
        path: /mcp/
        policies:
          tls:
            sni: api.githubcopilot.com
EOF
```

### 5.3 Create an HTTPRoute at `/mcp-github`

This sets CORS and injects the GitHub PAT as an Authorization header.

> **Note:** The `CORS` filter type is a kgateway extension, not part of standard Gateway API. It works with kgateway/agentgateway but won't work with other Gateway API implementations like Envoy Gateway.

```bash
kubectl apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mcp-github
  namespace: agentgateway-system
spec:
  parentRefs:
  - name: agentgateway-proxy
    namespace: agentgateway-system
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /mcp-github
      filters:
        - type: CORS
          cors:
            allowHeaders:
              - "*"
            allowMethods:
              - "*"
            allowOrigins:
              - "http://localhost:8080"
        - type: RequestHeaderModifier
          requestHeaderModifier:
            set:
              - name: Authorization
                value: "Bearer ${GH_PAT}"
      backendRefs:
      - name: github-mcp-backend
        group: agentgateway.dev
        kind: AgentgatewayBackend
EOF
```

### 5.4 Verify with MCP Inspector

Port-forward:
```bash
kubectl port-forward deployment/agentgateway-proxy -n agentgateway-system 8080:80
```

Run inspector:
```bash
npx modelcontextprotocol/inspector#0.18.0
```

Connect:
- Transport Type: Streamable HTTP
- URL: `http://localhost:8080/mcp-github`

Then go to Tools and click List Tools.

---

## 6) Tool allow/deny rules (AgentgatewayPolicy)

By default, all MCP tools are allowed. To restrict tools, attach an `AgentgatewayPolicy` to the backend and add CEL expressions.

### 6.1 Example: allow only a single tool (by name)

This example allows only the `get_me` tool on the GitHub MCP backend:

```bash
kubectl apply -f- <<'EOF'
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: github-tools-allowlist
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: github-mcp-backend
  backend:
    mcp:
      authorization:
        action: Allow
        policy:
          matchExpressions:
            - 'mcp.tool.name == "get_me"'
EOF
```

Re-connect in MCP Inspector and click List Tools again. You should only see the allowed tool.

### 6.2 Policy-as-code (programmatic management)

All allow/deny rules are Kubernetes resources:
- store YAML in Git
- apply with GitOps (Argo CD / Flux) or CI
- generate/patch them programmatically using the Kubernetes API (any client library)

Useful commands:
```bash
# show current policies
kubectl get agentgatewaypolicies -A

# update from file(s)
kubectl apply -f ./policies/

# quick patch example (change the match expression)
kubectl patch agentgatewaypolicy github-tools-allowlist -n agentgateway-system --type='json' \
  -p='[{"op":"replace","path":"/spec/backend/mcp/authorization/policy/matchExpressions/0","value":"mcp.tool.name == \\\"search_repositories\\\""}]'
```

---

## 7) Cleanup

```bash
# Option A cleanup
kubectl delete deployment mcp-website-fetcher
kubectl delete service mcp-website-fetcher
kubectl delete agentgatewaybackend mcp-backend
kubectl delete httproute mcp

# Option B cleanup
kubectl delete agentgatewaybackend github-mcp-backend -n agentgateway-system
kubectl delete httproute mcp-github -n agentgateway-system
kubectl delete agentgatewaypolicy github-tools-allowlist -n agentgateway-system

# proxy cleanup
kubectl delete gateway agentgateway-proxy -n agentgateway-system

# uninstall agentgateway
helm uninstall agentgateway -n agentgateway-system
helm uninstall agentgateway-crds -n agentgateway-system
```

---

## Troubleshooting

### Gateway Not Getting IP

```bash
# Check if MetalLB is working
kubectl get svc -n agentgateway-system agentgateway-proxy

# If no EXTERNAL-IP, check MetalLB
kubectl get pods -n metallb-system
kubectl get ipaddresspools -n metallb-system
```

### MCP Connection Issues

```bash
# Check agentgateway pods
kubectl get pods -n agentgateway-system
kubectl logs -n agentgateway-system -l app.kubernetes.io/name=agentgateway

# Check backend status
kubectl get agentgatewaybackends -A
kubectl describe agentgatewaybackend mcp-backend
```

### Policy Not Applied

```bash
# Check policy status
kubectl get agentgatewaypolicies -A
kubectl describe agentgatewaypolicy github-tools-allowlist -n agentgateway-system
```

---

## References

- [kgateway Documentation](https://kgateway.dev/)
- [Agentgateway Docs](https://kgateway.dev/docs/integrations/agentgateway/)
- [MCP Connectivity](https://kgateway.dev/docs/main/agentgateway/mcp/)
- [kgateway GitHub](https://github.com/kgateway-dev/kgateway)
- [Model Context Protocol](https://modelcontextprotocol.io/)
- [kgateway v2.1 Release Notes](https://kgateway.dev/blog/kgateway-v2.1-release-blog/)

---

*Created on a Saturday morning with the help of Claude Cowork and the relentless effort of Philippe Bogaerts for guiding, testing, and troubleshooting. Because nothing says "weekend fun" like debugging x509 certificate errors.* 🎉

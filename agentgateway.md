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
| **Control Plane** | Envoy Gateway controller | agentgateway controller |

### Key Concepts

| Term | Description |
|------|-------------|
| **MCP** | Model Context Protocol - standardizes how LLMs connect to external tools |
| **A2A** | Agent-to-Agent protocol - enables AI agents to communicate |
| **agentgateway** | Standalone control plane and data plane for AI/agent traffic (decoupled from kgateway since v1.0) |
| **AgentgatewayBackend** | Custom resource defining MCP server targets |
| **AgentgatewayPolicy** | Tool-level allow/deny rules (CEL expressions) |

### When to Use Which?

- **Envoy Gateway**: Web applications, REST APIs, microservices, traditional L7 routing
- **Agentgateway**: LLM tool servers, MCP integrations, AI agent orchestration, tool access control

You can run **both** in the same cluster - they use different GatewayClasses and don't conflict.

---

## Prerequisites

This guide assumes you already have:
- A working KIND cluster (from the Gateway API tutorial — `./setup.sh` in `gateway-api-lab/`)
- Gateway API CRDs installed (the tutorial installs the Experimental channel of v1.5.0)
- MetalLB installed and configured (so `LoadBalancer` Services get an IP)
- `kubectl` and `helm` installed

---

## Automated install (recommended)

As of May 2026, `gateway-api-lab/setup.sh` installs agentgateway and wires the Microsoft Learn MCP server automatically. Running `./setup.sh` with the default `INSTALL_AGENTGATEWAY=true` does steps 1, 2, 3 and 4 of this doc for you. Skip to [Section 5](#5-test-with-the-openai-agents-sdk) if you used the script.

To skip the AI-gateway step explicitly:

```bash
INSTALL_AGENTGATEWAY=false ./setup.sh
```

The sections below walk through what `setup.sh` does and how to do it by hand.

---

## 1) Install agentgateway (control plane)

As of agentgateway v1.0 the project was decoupled from kgateway and the Helm charts moved to `cr.agentgateway.dev/charts/`. The current stable line is **v1.1.x**.

```bash
export AGW_VERSION=v1.1.0
```

Install the CRDs (this also creates the `agentgateway-system` namespace):

```bash
helm upgrade -i agentgateway-crds \
  oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --create-namespace --namespace agentgateway-system \
  --version "${AGW_VERSION}"
```

Install the controller:

```bash
helm upgrade -i agentgateway \
  oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace agentgateway-system \
  --version "${AGW_VERSION}"
```

Verify the controller is running and the `agentgateway` GatewayClass was auto-created:

```bash
kubectl get pods -n agentgateway-system
kubectl get gatewayclass agentgateway
```

Expected GatewayClass output:

```
NAME           CONTROLLER                       ACCEPTED   AGE
agentgateway   agentgateway.dev/agentgateway    True       30s
```

---

## 2) Create an agentgateway proxy (Gateway)

This creates:

- a `Gateway` named `agentgateway-proxy`
- a backing `Deployment` and `Service` of the same name in `agentgateway-system`

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
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
EOF

kubectl wait --timeout=5m -n agentgateway-system \
  gateway/agentgateway-proxy --for=condition=Programmed
```

Inspect:

```bash
kubectl get gateway,deployment,svc -n agentgateway-system
```

### Access methods

| Platform | Method | Command |
|---|---|---|
| Linux | MetalLB EXTERNAL-IP (direct) | `kubectl get svc -n agentgateway-system agentgateway-proxy` then curl the IP |
| Linux | `kubectl port-forward` | `kubectl -n agentgateway-system port-forward deployment/agentgateway-proxy 8080:80` |
| macOS | `kubectl port-forward` (required — MetalLB IP is not routable from the host) | `kubectl -n agentgateway-system port-forward deployment/agentgateway-proxy 8080:80` |
| macOS | `docker exec` into a kind node | `docker exec gateway-api-lab-control-plane curl ...` against the MetalLB IP |
| macOS | OrbStack | Linux commands "just work" |

For the OpenAI Agents SDK test in Section 5, **use port-forward on both platforms** so the script can target `http://localhost:8080/`.

---

## 3) Option A: Route to a local MCP server (static MCP)

### 3.1 Deploy a sample MCP server (website fetcher)

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

### 3.2 Create an AgentgatewayBackend

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

### 3.3 Create an HTTPRoute to the MCP backend

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

### 3.4 Verify with MCP Inspector

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

## 4) Option B: Route to the remote Microsoft Learn MCP server (HTTPS, anonymous)

[Microsoft Learn MCP](https://learn.microsoft.com/en-us/training/support/mcp) is a public, anonymous streamable-HTTP MCP server hosted at `https://learn.microsoft.com/api/mcp`. It exposes tools for searching Microsoft documentation and fetching articles and code samples. No API key, no PAT — it just works.

This is what `setup.sh` configures automatically. The two manifests below are the same ones the script applies.

### 4.1 Create an AgentgatewayBackend for Microsoft Learn MCP

```bash
kubectl apply -f- <<'EOF'
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: mslearn-mcp-backend
  namespace: agentgateway-system
spec:
  mcp:
    targets:
      - name: mslearn-target
        static:
          host: learn.microsoft.com
          port: 443
          path: /api/mcp
          protocol: StreamableHTTP
          policies:
            tls:
              sni: learn.microsoft.com
EOF
```

Notes on the fields:
- `protocol: StreamableHTTP` — Microsoft Learn MCP uses the MCP streamable-HTTP transport (one HTTP endpoint that can upgrade to SSE for streaming responses). The other valid value is `SSE` for SSE-only upstreams.
- `path: /api/mcp` — the path on the upstream where the MCP endpoint lives.
- `policies.tls.sni` — required because Microsoft's load balancer relies on SNI to route to the right backend.

### 4.2 Create an HTTPRoute at `/mcp-mslearn`

```bash
kubectl apply -f- <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mcp-mslearn
  namespace: agentgateway-system
spec:
  parentRefs:
    - name: agentgateway-proxy
      namespace: agentgateway-system
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /mcp-mslearn
      backendRefs:
        - name: mslearn-mcp-backend
          group: agentgateway.dev
          kind: AgentgatewayBackend
EOF
```

Clients now reach Microsoft Learn MCP at `http://<agentgateway-proxy>/mcp-mslearn`.

---

## 5) Test with the OpenAI Agents SDK

The Microsoft Learn docs explicitly recommend using an agent framework rather than calling the MCP endpoint directly. We use the [OpenAI Agents SDK](https://openai.github.io/openai-agents-python/) for this, which has first-class support for streamable-HTTP MCP servers via `MCPServerStreamableHttp`.

### 5.1 Port-forward (both macOS and Linux)

The agentgateway proxy Service has a MetalLB EXTERNAL-IP, but on macOS that IP is not reachable from your host (Docker Desktop runs containers inside a Linux VM). The simplest cross-platform option is port-forward — keep it running in a dedicated terminal:

```bash
kubectl -n agentgateway-system port-forward \
  deployment/agentgateway-proxy 8080:80
```

On Linux you can alternatively curl the MetalLB IP directly, but port-forward keeps the rest of this section identical between platforms.

### 5.2 Install the OpenAI Agents SDK and export your API key

```bash
pip install --upgrade openai-agents
export OPENAI_API_KEY=sk-...
```

### 5.3 Run the included test client

`gateway-api-lab/test-mslearn-agent.py` connects to `http://localhost:8080/mcp-mslearn`, asks the agent a Microsoft-docs question, and prints the answer. Reproduced here for reference — see the file in the repo for the runnable copy:

```python
import asyncio, os, sys
from agents import Agent, Runner
from agents.mcp import MCPServerStreamableHttp

async def main():
    async with MCPServerStreamableHttp(
        name="Microsoft Learn Docs",
        params={"url": "http://localhost:8080/mcp-mslearn", "timeout": 30},
        cache_tools_list=True,
    ) as mcp_server:
        tools = await mcp_server.list_tools()
        print("Tools:", ", ".join(t.name for t in tools), file=sys.stderr)

        agent = Agent(
            name="Microsoft docs assistant",
            instructions=(
                "Use Microsoft Learn MCP tools to search official docs "
                "before answering. Cite the URLs you used."
            ),
            model=os.environ.get("OPENAI_MODEL", "gpt-4o-mini"),
            mcp_servers=[mcp_server],
        )
        result = await Runner.run(
            agent,
            "What is Azure App Service and what languages does it support?",
        )
        print(result.final_output)

asyncio.run(main())
```

Run it:

```bash
cd gateway-api-lab
python3 test-mslearn-agent.py
```

What you should see:

1. A short line on stderr listing the tools Microsoft Learn MCP exposes — typically `microsoft_docs_search`, `microsoft_docs_fetch`, plus one or two related tools.
2. A multi-paragraph answer that quotes specific Microsoft Learn URLs.

If the Agent hangs or the tool list is empty, the most common causes are:
- Port-forward isn't running (or is binding a different port).
- The `mslearn-mcp-backend` AgentgatewayBackend is missing `protocol: StreamableHTTP`, in which case agentgateway defaults to SSE and silently fails the streamable-HTTP handshake.
- Egress from the cluster to `learn.microsoft.com:443` is blocked (rare for local KIND, common in corporate environments).

---

## 6) Tool allow/deny rules (AgentgatewayPolicy)

By default, all MCP tools are allowed. To restrict tools, attach an `AgentgatewayPolicy` to the backend and add CEL expressions.

### 6.1 Example: allow only doc search on Microsoft Learn MCP

This restricts the Microsoft Learn backend to a single tool — `microsoft_docs_search`. Re-running the OpenAI Agents SDK test from Section 5 after applying the policy will show only that tool in `mcp_server.list_tools()`, and the agent will be unable to fetch full articles or code samples.

```bash
kubectl apply -f- <<'EOF'
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: mslearn-tools-allowlist
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: mslearn-mcp-backend
  backend:
    mcp:
      authorization:
        action: Allow
        policy:
          matchExpressions:
            - 'mcp.tool.name == "microsoft_docs_search"'
EOF
```

Re-run `python3 test-mslearn-agent.py` (or reconnect in MCP Inspector) — the tool list should now contain only `microsoft_docs_search`.

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
kubectl patch agentgatewaypolicy mslearn-tools-allowlist -n agentgateway-system --type='json' \
  -p='[{"op":"replace","path":"/spec/backend/mcp/authorization/policy/matchExpressions/0","value":"mcp.tool.name == \\\"microsoft_docs_fetch\\\""}]'
```

---

## 7) Cleanup

```bash
# Option A cleanup (local website-fetcher MCP)
kubectl delete deployment mcp-website-fetcher
kubectl delete service mcp-website-fetcher
kubectl delete agentgatewaybackend mcp-backend
kubectl delete httproute mcp

# Option B cleanup (Microsoft Learn MCP — what setup.sh creates)
kubectl delete agentgatewaybackend mslearn-mcp-backend -n agentgateway-system
kubectl delete httproute mcp-mslearn -n agentgateway-system
kubectl delete agentgatewaypolicy mslearn-tools-allowlist -n agentgateway-system 2>/dev/null || true

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

- [Agentgateway Docs](https://agentgateway.dev/docs/kubernetes/main/)
- [Agentgateway Helm install](https://agentgateway.dev/docs/kubernetes/main/install/helm/)
- [Agentgateway MCP connectivity](https://agentgateway.dev/docs/kubernetes/main/mcp/)
- [Agentgateway GitHub](https://github.com/agentgateway/agentgateway)
- [Microsoft Learn MCP Server](https://learn.microsoft.com/en-us/training/support/mcp)
- [OpenAI Agents SDK – MCP](https://openai.github.io/openai-agents-python/mcp/)
- [Model Context Protocol](https://modelcontextprotocol.io/)
- [kgateway (umbrella project)](https://kgateway.dev/)

---

*Created on a Saturday morning with the help of Claude Cowork and the relentless effort of Philippe Bogaerts for guiding, testing, and troubleshooting. Because nothing says "weekend fun" like debugging x509 certificate errors.* 🎉

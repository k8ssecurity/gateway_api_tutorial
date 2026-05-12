# Kubernetes Gateway API Lab

A complete hands-on lab for the Kubernetes Gateway API. You get a local KIND cluster with Cilium, MetalLB, Envoy Gateway, and Agentgateway all wired together, plus two tutorial docs that walk through the setup at different depths.

Target audience: network engineers comfortable with Linux/Docker but new to Kubernetes, and AI engineers who want a realistic place to experiment with MCP traffic through a real gateway.

## What you get

After `./setup.sh` you have a working cluster with:

- 3-node KIND cluster (1 control-plane + 2 workers)
- Cilium CNI with kube-proxy replacement
- MetalLB handing out LoadBalancer IPs from the Docker bridge
- Gateway API CRDs (Experimental channel)
- Envoy Gateway routing a sample webapp on HTTP/HTTPS, with stable + canary deployments and example HTTPRoutes for traffic-split, header-match, and TLSRoute passthrough
- Agentgateway exposing the public Microsoft Learn MCP server at `/mcp-mslearn`
- An OpenAI Agents SDK test client (`test-mslearn-agent.py`) that drives the MCP server through the gateway

## Where to read next

- [`kubernetes-gateway-api-tutorial.md`](kubernetes-gateway-api-tutorial.md) — main tutorial. Walks through the cluster, Cilium, MetalLB, Envoy Gateway, the sample app, and the HTTPRoute/TLSRoute examples. Includes a Quick Start section and explicit macOS vs Linux testing paths.
- [`agentgateway.md`](agentgateway.md) — the AI-gateway extension. Installs agentgateway alongside Envoy Gateway, wires Microsoft Learn MCP as an `AgentgatewayBackend`, and validates the path end-to-end with the OpenAI Agents SDK. Read this after the main tutorial.

Both docs assume the same lab folder, so the cluster you build in the first tutorial is the one extended in the second.

## Quick start

```bash
cd gateway-api-lab
./setup.sh
```

That runs the full sequence — cluster, CNI, MetalLB, Gateway API, Envoy Gateway, sample app + routes, agentgateway, Microsoft Learn MCP route, `/etc/hosts` update, and a printout of platform-appropriate test commands at the end.

To skip the AI-gateway step:

```bash
INSTALL_AGENTGATEWAY=false ./setup.sh
```

## Repository layout

```
.
├── README.md                              ← you are here
├── kubernetes-gateway-api-tutorial.md     ← Envoy Gateway walkthrough
├── agentgateway.md                        ← Agentgateway / MCP walkthrough
└── gateway-api-lab/
    ├── setup.sh                           ← end-to-end installer
    ├── cleanup.sh                         ← tear it all down
    ├── test-mslearn-agent.py              ← OpenAI Agents SDK test client
    │
    ├── 01-kind-config.yaml                ← cluster topology
    ├── 02-metallb-config.yaml             ← LoadBalancer IP pool (static fallback)
    ├── 03-gateway.yaml                    ← Envoy Gateway: eg-gateway (80/443)
    ├── 04-webapp.yaml                     ← sample app: stable
    ├── 05-webapp-canary.yaml              ← sample app: canary
    ├── 06-httproute-basic.yaml            ← Envoy: route all → stable
    ├── 07-httproute-canary.yaml           ← Envoy: 90/10 traffic split
    ├── 08-httproute-header.yaml           ← Envoy: route by X-Canary header
    ├── 09-tlsroute-passthrough.yaml       ← Envoy: TLS passthrough (SNI-based)
    ├── 10-agentgateway.yaml               ← Agentgateway: proxy Gateway
    └── 11-mcp-mslearn.yaml                ← Agentgateway: Microsoft Learn MCP route
```

## Pinned versions (May 2026)

The script pins known-working versions so the lab is reproducible:

| Component | Version |
|---|---|
| Cilium | 1.19.3 |
| MetalLB | v0.15.3 |
| Gateway API | v1.5.0 (Experimental channel) |
| Envoy Gateway | v1.7.3 |
| Agentgateway | v1.1.0 |

## macOS vs Linux — one thing to know

On Linux, the MetalLB IPs live on the host's Docker bridge — `curl http://<gateway-ip>/` from your shell just works.

On macOS, Docker Desktop runs containers inside a Linux VM. The MetalLB IPs are inside that VM and **not routable from your Mac terminal**. To test against either gateway, use one of:

1. `kubectl port-forward` — works everywhere, recommended.
2. `docker exec gateway-api-lab-control-plane curl ...` — runs the request from inside the kind network.

Both tutorials and `setup.sh`'s final output show concrete examples for each path.

## Prerequisites

| Tool | Purpose |
|---|---|
| Docker (Desktop or Engine) | Container runtime |
| `kubectl` | Kubernetes CLI |
| `kind` | Kubernetes-in-Docker |
| `helm` | Package manager for Envoy Gateway + agentgateway |
| `cilium` CLI | CNI install/management |
| `openssl` | TLS certificate generation |
| `python3` + `pip` | Only for the OpenAI Agents SDK test client |

Installation commands for both macOS and Linux are in [Part 1 of the main tutorial](kubernetes-gateway-api-tutorial.md#part-1-environment-setup).

## Cleanup

```bash
cd gateway-api-lab
./cleanup.sh        # or: kind delete cluster --name gateway-api-lab
```

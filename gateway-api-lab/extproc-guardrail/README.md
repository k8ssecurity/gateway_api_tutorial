# ExtProc intent guardrail — PoC

A custom **Envoy ext_proc** gRPC server that agentgateway calls out to per request,
so it can **inspect the request body** — the MCP `tools/call` (tool name + arguments)
and the LLM chat prompt — and decide **allow / block** based on intent.

Idea: a "WAF for tool calls / prompts" — block *abusive parameters* (e.g. a search
to `deploy …`, or a prompt to `execute …`) while allowing benign ones (`explain …`,
`teach me …`).

```
client → agentgateway ──ext_proc(gRPC)──▶ guardrail (this server)
                          │  inspects tool/prompt + args → ALLOW / BLOCK
                          ▼
                   MCP / LLM upstream
```

## What it does

| Leg | Route | Block keywords | Example blocked | Example allowed |
|-----|-------|----------------|-----------------|-----------------|
| LLM | `/openai` | `execute` | "execute a deployment" | "teach me …" |
| MCP | `/mcp-mslearn` | `deploy`, `execute this` | search "how to deploy …" | search "explain …" |

The server implements `envoy.service.ext_proc.v3.ExternalProcessor`, asks for the
buffered request body, parses it (JSON-RPC for MCP, chat JSON for LLM) and logs a
clear decision, e.g.:

```
⛔ BLOCK leg=MCP path=/mcp-mslearn — matched "deploy" [method=tools/call tool=microsoft_docs_search query="how to deploy azure app service"]
✅ ALLOW leg=MCP path=/mcp-mslearn — no blocked keyword [method=tools/call tool=microsoft_docs_search query="explain azure app service"]
⛔ BLOCK leg=LLM path=/openai/chat/completions — matched "execute" [last_msg="please execute a production deployment"]
✅ ALLOW leg=LLM path=/openai/chat/completions — no blocked keyword [last_msg="teach me what Azure App Service is"]
```

## Status (agentgateway v1.2.1) — important

**Inspection / decision: WORKS.** The guardrail reliably receives and parses the
full MCP tool call (name + arguments) and the LLM prompt, and decides allow/block
(see logs above). This proves the core idea: an ext_proc callout *can* see the tool
call + parameters and judge intent.

**Enforcement (forward-on-allow / block-on-deny): does NOT work on the request-body
path in v1.2.1.** Per agentgateway's own
[ext_proc compatibility notes](https://agentgateway.dev/docs/standalone/latest/configuration/traffic-management/extproc/):

> - Headers and Body are *always* sent, with Body in **streaming** mode.
> - `mode_override` … is **ignored**.

So you cannot request `BUFFERED` mode, and empirically the request reaches the
upstream with an **empty body** regardless of whether the server passes the body
through or returns an `ImmediateResponse` — i.e. allowed requests break (HTTP 503/400
"empty body") and blocks don't return a clean 403. The docs say request termination
*should* be possible, so this looks like a request-body ext_proc gap/bug in v1.2.1
(worth filing upstream).

### Practical takeaway

- Use this server as an **observe/alert** guardrail today (it logs every abusive
  tool call / prompt) — that alone is a useful detection control.
- For real **enforcement**:
  - **LLM** — use agentgateway's purpose-built **guardrail webhook** (supported,
    content-based pass/mask/reject): `…/llm/guardrails/webhook`.
  - **MCP tools** — use native **CEL authorization** (`mcp.authorization`, static
    allow-list by tool name) until request-body ext_proc enforcement is fixed.

## Build & deploy

```bash
# 1) build (multi-stage; only Docker needed on the host) and load into kind
docker build -t extproc-guardrail:poc .
kind load docker-image extproc-guardrail:poc --name gateway-api-lab

# 2) deploy the server + Service (and, to experiment, the ext_proc policy)
kubectl apply -f ../14-extproc-guardrail.yaml

# 3) watch decisions
kubectl -n agentgateway-system logs deploy/ext-proc-guardrail -f
```

> The `AgentgatewayPolicy` in `14-extproc-guardrail.yaml` attaches ext_proc to the
> whole `agentgateway-proxy` Gateway. Because of the v1.2.1 request-body gap above,
> applying it currently breaks request forwarding — keep it for experimentation /
> observe-mode, and remove it (`kubectl -n agentgateway-system delete agentgatewaypolicy ext-proc-guardrail`)
> to restore normal routing.

## Files

- `main.go` — the ext_proc gRPC server (go-control-plane).
- `Dockerfile` — multi-stage build → distroless static image.
- `../14-extproc-guardrail.yaml` — Deployment + Service + AgentgatewayPolicy(extProc).

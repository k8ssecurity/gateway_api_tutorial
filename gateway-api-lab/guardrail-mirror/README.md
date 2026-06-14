# guardrail-mirror — observe-mode intent sensor (PoC) + findings

Goal: get a **full trace of every tool call / prompt** through agentgateway by
sending a **copy** of each request to a small HTTP server (via a Gateway API
`RequestMirror` filter), so the live path is untouched and we just observe +
verdict the intent (deploy/execute → flag, explain/teach-me → ok).

A plain Go `net/http` server (`main.go`) receives the mirrored request and logs a
verdict. Build/deploy is in `../15-guardrail-mirror.yaml`.

## Finding (agentgateway v1.2.1) — the body never reaches an external callout

This PoC, together with the sibling `../extproc-guardrail`, establishes that on
**agentgateway v1.2.1 you cannot inspect the request *body* from an external
callout**:

| Mechanism | Live path | Body delivered to inspector? | Net |
|-----------|-----------|------------------------------|-----|
| **ext_proc** (`../extproc-guardrail`) | **breaks** | yes (full body, parsed) | inspector sees the tool/prompt, but the upstream then gets an **empty body** and the block/`ImmediateResponse` isn't applied — `mode_override` is ignored, body is streamed-only. |
| **RequestMirror** (this) | fine (200) | **no** — mirror arrives `Content-Length: 0`, `bodyLen=0` | live traffic is untouched, but the copy has **no body**, so there's nothing to inspect. |

Verified live trace from the mirror:

```
✅ ALLOW LLM /openai/chat/completions method=POST CL=0 bodyLen=0 ct="application/json" | (unparsed)
```

So: ext_proc sees the body but can't enforce/forward; mirror is safe but carries
no body. Either way, a custom **content** guardrail over a callout isn't possible
on this version. (Both are worth a bug report upstream — the docs imply request
termination and mirroring-with-body should work.)

## What DOES work for a full content trace

The gateway itself parses the bodies (for routing / LLM translation / guardrails),
so the content is available **inside** agentgateway — use its native
observability rather than an external callout:

- **Access logging with CEL fields** — log extracted fields such as
  `mcp.tool.name`, `json(request.body).params.arguments.query`, and `llm.*`
  (token usage, model). See the CEL examples:
  https://agentgateway.dev/docs/kubernetes/latest/reference/cel/yaml-and-examples/
- **LLM observability** and **MCP observability** — prompt/tool telemetry.
- **OpenTelemetry tracing** — per-request spans.

These are configured at the **gateway level** (AgentgatewayParameters / Helm /
listener config), not via a per-route policy.

## What to use for enforcement

- **LLM** content block → built-in **guardrail webhook** (pass/mask/reject).
- **MCP tools** → **CEL authorization** (`mcp.authorization`, allow-list by tool
  name). Argument-level blocking needs the request-body callout fix above.

## Status

Deployed (`guardrail-mirror` in `agentgateway-system`); the `RequestMirror`
filters were removed from the routes after testing (no value with an empty body),
so normal routing is restored. The Deployment is left idle for experimentation.

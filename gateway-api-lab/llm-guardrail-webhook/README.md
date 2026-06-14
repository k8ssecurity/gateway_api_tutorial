# LLM guardrail webhook + full-trace access logging — WORKING PoC

This is the **working** pair (vs. the `../extproc-guardrail` / `../guardrail-mirror`
explorations, which hit agentgateway v1.2.1 body-handling gaps). It uses
agentgateway's **own** body parsing, so both enforcement and tracing get the content.

## 1. Enforce — block LLM calls on content (guardrail webhook)

`main.go` is an agentgateway Guardrail Webhook server. The gateway parses the
prompt and calls `POST /request` *before* the LLM; the webhook returns pass/reject.

Policy: block prompts containing **"execute"**, allow the rest (e.g. "teach me").

```bash
cd gateway-api-lab/llm-guardrail-webhook
docker build -t llm-guardrail-webhook:poc .
kind load docker-image llm-guardrail-webhook:poc --name gateway-api-lab
kubectl apply -f ../16-llm-guardrail-webhook.yaml      # Deployment + Service + promptGuard policy
```

Verified on the lab:

```
"execute a production deployment now"  -> HTTP 403  "Blocked by LLM guardrail: prompt contains "execute""
"teach me what Azure App Service is"   -> HTTP 200  (real completion)
```

Contract (from the agentgateway Guardrail Webhook API):
`POST /request` ← `{"body":{"messages":[{"role","content"}]}}`,
reply `{"action":{"reason":"passed"}}` (pass) or
`{"action":{"body":"...","status_code":403,"reason":"..."}}` (reject).

### Response guardrail (mask PII / secrets in the completion)

The same webhook also implements `POST /response` (wired via `promptGuard.response`).
It redacts emails and the word "secret" from the LLM's answer before it reaches
the client. Response actions are pass/**mask** (modify) — not a hard reject.

Verified on the lab:

```
prompt "two example email addresses"   -> OUTPUT: "[REDACTED-EMAIL] [REDACTED-EMAIL]"
prompt "The secret code is alpha."      -> OUTPUT: "The [REDACTED] code is alpha."
```

Contract: `POST /response` ← `{"body":{"choices":[{"message":{"role","content"}}]}}`,
reply `{"action":{"reason":"passed"}}` (pass) or
`{"action":{"body":{"choices":[...]},"reason":"..."}}` (mask — return the modified choices).

## 2. Trace — full audit of every tool call + prompt (access logging)

`../17-access-log-trace.yaml` enables the gateway's native access log with a CEL
field `string(request.body)`, so every request's full payload is logged.

```bash
kubectl apply -f ../17-access-log-trace.yaml
kubectl -n agentgateway-system logs deploy/agentgateway-proxy -f
```

Sample trace lines:

```
http.status=200 protocol=llm gen_ai.request.model=gpt-4o-mini gen_ai.usage.input_tokens=12 gen_ai.usage.output_tokens=987 \
  trace.body="{"model":"gpt-4o-mini","messages":[{"role":"user","content":"teach me kubernetes"}]}"

http.path=/mcp-mslearn protocol=mcp \
  trace.body="{"jsonrpc":"2.0","method":"tools/call","params":{"name":"microsoft_docs_search","arguments":{"query":"how to deploy azure app service"}}}"
```

You get the MCP tool name + arguments and the LLM prompt, plus built-in GenAI
telemetry (model, token counts) for free. Blocked requests are traced too.

> Logging full bodies includes prompt content — fine for a lab; scope with the
> CEL `filter` and targeted fields (redaction) before production.

## Why this works (and the callouts didn't)

Enforcement and tracing here run **inside** agentgateway, which already parses the
LLM/MCP bodies. External callouts can't: on v1.2.1 ext_proc gets the body but
can't forward/block it, and request-mirror copies arrive with no body (see the
sibling PoC READMEs).

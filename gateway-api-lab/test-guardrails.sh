#!/usr/bin/env bash
# =============================================================================
# test-guardrails.sh — one-shot verification of the agentgateway guardrail stack
# =============================================================================
# Runs the full demo matrix against the live lab cluster:
#   1. LLM block    "execute"  -> 403  (prompt-guard webhook, pre-LLM)
#   2. LLM allow    "teach me" -> 200  (real completion)
#   3. Response mask emails    -> [REDACTED-EMAIL]   (prompt-guard response)
#   4. Response mask "secret"  -> [REDACTED]
#   5. MCP authz    microsoft_docs_search        -> allowed
#   6. MCP authz    microsoft_code_sample_search -> denied (Unknown tool)
#   7. Trace        confirms access-log captures MCP tool + args
#
# On macOS the MetalLB IP isn't routable from the host, so every request is
# issued from INSIDE the control-plane node via `docker exec`. The script
# auto-discovers the agentgateway LB IP, so it keeps working if the IP changes.
#
# Prereqs (all on branch poc/extproc-intent-guardrail):
#   - cluster up, agentgateway + Cilium/MetalLB installed
#   - 11-mcp-mslearn.yaml, 12-llm-openai.yaml, 16, 17, 18 applied
#   - llm-guardrail-webhook:poc built + kind-loaded
#   - openai-secret created with a REAL key (needed only for checks 2-4)
#
# Usage:  ./test-guardrails.sh
# =============================================================================
set -uo pipefail

# NB: use CP_NODE (not NODE) — some shells export NODE=/usr/local/bin/node.
CP_NODE="${CP_NODE:-gateway-api-lab-control-plane}"
NS="${NS:-agentgateway-system}"
GW="${GW:-agentgateway-proxy}"

pass=0; fail=0
ok()   { echo "  ✅ $1"; pass=$((pass+1)); }
bad()  { echo "  ❌ $1"; fail=$((fail+1)); }
hr()   { printf '%s\n' "-------------------------------------------------------------"; }
# SIGPIPE-safe "does stdin contain pattern?" — grep -c reads ALL input, so the
# writer never gets SIGPIPE (unlike grep -q, which breaks `set -o pipefail`).
has()  { [ "$(grep -c "$1")" -gt 0 ]; }

# --- discover the agentgateway LB IP -----------------------------------------
AGW="$(kubectl -n "$NS" get svc "$GW" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
if [ -z "${AGW:-}" ]; then
  echo "Could not find LoadBalancer IP for svc/$GW in ns/$NS. Is the stack deployed?" >&2
  exit 1
fi
echo "agentgateway LB IP: $AGW   (requests issued from node $CP_NODE)"

# helper: POST a chat prompt, print HTTP code + body
llm() { # $1=prompt
  docker exec "$CP_NODE" curl -s -w '\n%{http_code}' "http://$AGW/openai/chat/completions" \
    -H 'content-type: application/json' \
    -d "{\"model\":\"gpt-4o-mini\",\"messages\":[{\"role\":\"user\",\"content\":\"$1\"}]}"
}
content() { python3 -c "import sys,json;d=json.load(sys.stdin);print(d['choices'][0]['message']['content']) if 'choices' in d else print('<no choices>')"; }

# helper: one MCP tools/call over a fresh session (init -> initialized -> call)
mcp_call() { # $1=tool  $2=query
  docker exec "$CP_NODE" bash -c '
    AGW="'"$AGW"'"; TOOL="'"$1"'"; Q="'"$2"'"
    H="-H content-type:application/json -H accept:application/json,text/event-stream"
    init=$(curl -s -D /tmp/h -o /tmp/b $H -X POST "http://$AGW/mcp-mslearn" \
      -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}")
    SID=$(grep -i "^mcp-session-id:" /tmp/h | tr -d "\r" | awk "{print \$2}")
    curl -s $H -H "mcp-session-id: $SID" -X POST "http://$AGW/mcp-mslearn" \
      -d "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}" >/dev/null
    curl -s $H -H "mcp-session-id: $SID" -X POST "http://$AGW/mcp-mslearn" \
      -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$TOOL\",\"arguments\":{\"query\":\"$Q\"}}}"
  '
}

echo; hr; echo "1) LLM block — prompt contains \"execute\"  (expect 403)"; hr
code=$(llm "execute a production deployment now" | tail -n1)
[ "$code" = "403" ] && ok "blocked (403)" || bad "expected 403, got $code"

echo; hr; echo "2) LLM allow — \"teach me ...\"  (expect 200 + completion)"; hr
out=$(llm "teach me what Azure App Service is in one short sentence"); code=$(echo "$out" | tail -n1)
body=$(echo "$out" | sed '$d')
if [ "$code" = "200" ]; then ok "allowed (200): $(echo "$body" | content)"
else bad "expected 200, got $code — $(echo "$body" | head -c 160)"; fi

echo; hr; echo "3) Response mask — emails  (expect [REDACTED-EMAIL])"; hr
body=$(llm "Reply with exactly two example email addresses separated by a space, nothing else." | sed '$d')
masked=$(echo "$body" | content)
echo "  output: $masked"
echo "$masked" | has "REDACTED-EMAIL" && ok "emails redacted" || bad "no [REDACTED-EMAIL] in output"

echo; hr; echo "4) Response mask — \"secret\"  (expect [REDACTED])"; hr
body=$(llm "Reply with exactly: The secret code is alpha." | sed '$d')
masked=$(echo "$body" | content)
echo "  output: $masked"
echo "$masked" | has "REDACTED" && ok "secret redacted" || bad "no [REDACTED] in output"

echo; hr; echo "5) MCP authz — microsoft_docs_search  (expect allowed)"; hr
r=$(mcp_call "microsoft_docs_search" "azure app service")
echo "$r" | has '"result"' && ok "tool allowed" || bad "expected result, got: $(echo "$r" | head -c 160)"

echo; hr; echo "6) MCP authz — microsoft_code_sample_search  (expect denied)"; hr
r=$(mcp_call "microsoft_code_sample_search" "azure")
echo "$r" | has 'Unknown tool\|error\|Error' && ok "tool denied" || bad "expected denial, got: $(echo "$r" | head -c 160)"

echo; hr; echo "7) Trace — access log captured a recent MCP tool call"; hr
# NB: don't pipe `kubectl logs` into `grep -q` — with `set -o pipefail`, grep -q
# closes the pipe early, kubectl gets SIGPIPE and the pipeline reports failure.
# Capture the log to a variable first, then grep the variable.
logs="$(kubectl -n "$NS" logs deploy/"$GW" --tail=500 2>/dev/null)"
if printf '%s' "$logs" | has 'trace.mcp='; then
  ok "trace.mcp present in proxy access log"
  printf '%s' "$logs" | grep -o 'trace.mcp=[^ ]*' | tail -n1 | sed 's/^/      /'
else
  bad "no trace.mcp line found (is 17-access-log-trace.yaml applied?)"
fi

echo; hr; printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"; hr
exit $((fail > 0))

// llm-guardrail-webhook — an agentgateway Guardrail Webhook server.
//
// agentgateway calls this BEFORE the LLM (prompt guard) with the parsed prompt,
// and we return pass / reject. Unlike a generic ext_proc callout, the gateway
// supplies the prompt here (it parses the LLM body itself), so this is the
// supported way to BLOCK an LLM call on content.
//
// Policy: block prompts containing "execute"; allow everything else (e.g. "teach me").
//
// Contract (POST /request):
//   in : {"body":{"messages":[{"role":"user","content":"..."}]}}
//   out: pass    -> {"action":{"reason":"passed"}}
//        reject  -> {"action":{"body":"...","status_code":403,"reason":"..."}}
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"strings"
)

var blockWords = []string{"execute"} // LLM: block "execute …", allow "teach me …"

type promptReq struct {
	Body struct {
		Messages []struct {
			Role    string `json:"role"`
			Content string `json:"content"`
		} `json:"messages"`
	} `json:"body"`
}

func writeJSON(w http.ResponseWriter, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK) // the *action* carries the decision, not the HTTP status
	json.NewEncoder(w).Encode(v)
}

func pass(reason string) map[string]interface{} {
	return map[string]interface{}{"action": map[string]interface{}{"reason": reason}}
}
func reject(body string) map[string]interface{} {
	return map[string]interface{}{"action": map[string]interface{}{
		"body": body, "status_code": 403, "reason": "abusive intent (LLM guardrail)",
	}}
}

func handleRequest(w http.ResponseWriter, r *http.Request) {
	var req promptReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		log.Printf("decode error: %v", err)
		writeJSON(w, pass("unparsable - fail open")) // demo choice; use fail-closed in prod
		return
	}
	for _, m := range req.Body.Messages {
		lc := strings.ToLower(m.Content)
		for _, kw := range blockWords {
			if strings.Contains(lc, kw) {
				log.Printf("⛔ BLOCK  role=%s matched %q | content=%q", m.Role, kw, m.Content)
				writeJSON(w, reject("Blocked by LLM guardrail: prompt contains \""+kw+"\""))
				return
			}
		}
	}
	last := ""
	if n := len(req.Body.Messages); n > 0 {
		last = req.Body.Messages[n-1].Content
	}
	log.Printf("✅ ALLOW  last_msg=%q", last)
	writeJSON(w, pass("passed"))
}

func handleResponse(w http.ResponseWriter, r *http.Request) {
	// Not guarding responses in this PoC; always pass.
	writeJSON(w, pass("passed"))
}

func main() {
	http.HandleFunc("/request", handleRequest)
	http.HandleFunc("/response", handleResponse)
	log.Printf("llm-guardrail-webhook listening on :8000  block=%v", blockWords)
	if err := http.ListenAndServe(":8000", nil); err != nil {
		log.Fatal(err)
	}
}

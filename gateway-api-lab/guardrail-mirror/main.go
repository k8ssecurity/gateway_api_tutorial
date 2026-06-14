// guardrail-mirror — an OBSERVE-mode intent guardrail.
//
// agentgateway mirrors a COPY of each request (headers + body) to this plain
// HTTP server via a Gateway API RequestMirror filter. The live request is
// untouched and this server's response is ignored — so this is a detection /
// audit / "full trace" sensor, not an inline blocker.
//
// It parses the mirrored body and logs a verdict per request:
//   * LLM  (/openai)      flag "execute"            (e.g. allow "teach me")
//   * MCP  (/mcp-mslearn) flag "deploy"/"execute this" (e.g. allow "explain")
package main

import (
	"bytes"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"strings"
)

var (
	llmFlag = []string{"execute"}
	mcpFlag = []string{"deploy", "execute this"}
)

func summarize(leg string, body []byte) string {
	switch leg {
	case "MCP":
		var m struct {
			Method string `json:"method"`
			Params struct {
				Name      string                 `json:"name"`
				Arguments map[string]interface{} `json:"arguments"`
			} `json:"params"`
		}
		if json.Unmarshal(body, &m) == nil && m.Method != "" {
			q, _ := m.Params.Arguments["query"].(string)
			return "method=" + m.Method + " tool=" + m.Params.Name + " query=\"" + q + "\""
		}
	case "LLM":
		var m struct {
			Model    string `json:"model"`
			Messages []struct {
				Role    string `json:"role"`
				Content string `json:"content"`
			} `json:"messages"`
		}
		if json.Unmarshal(body, &m) == nil {
			last := ""
			if n := len(m.Messages); n > 0 {
				last = m.Messages[n-1].Content
			}
			return "model=" + m.Model + " last_msg=\"" + last + "\""
		}
	}
	return "(unparsed)"
}

func compact(body []byte) string {
	var buf bytes.Buffer
	if json.Compact(&buf, body) == nil {
		return buf.String()
	}
	return string(body)
}

func handler(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	r.Body.Close()
	path := r.URL.Path
	text := strings.ToLower(string(body))

	var leg string
	var flags []string
	switch {
	case strings.Contains(strings.ToLower(path), "openai"):
		leg, flags = "LLM", llmFlag
	case strings.Contains(strings.ToLower(path), "mcp"):
		leg, flags = "MCP", mcpFlag
	default:
		leg, flags = "HTTP", nil
	}

	verdict, matched := "ALLOW", ""
	for _, kw := range flags {
		if strings.Contains(text, kw) {
			verdict, matched = "BLOCK", kw
			break
		}
	}
	icon := "✅"
	reason := "no flagged keyword"
	if verdict == "BLOCK" {
		icon = "⛔"
		reason = "flagged \"" + matched + "\""
	}

	// Full trace.
	log.Printf("%s %-4s %-7s %s method=%s CL=%d bodyLen=%d ct=%q te=%q | %s | %s",
		icon, verdict, leg, path, r.Method, r.ContentLength, len(body),
		r.Header.Get("Content-Type"), r.Header.Get("Transfer-Encoding"),
		summarize(leg, body), reason)
	log.Printf("        raw[%dB]: %s", len(body), compact(body))

	w.WriteHeader(http.StatusOK)
	io.WriteString(w, "observed\n")
}

func main() {
	http.HandleFunc("/", handler)
	log.Printf("guardrail-mirror (observe-mode) listening on :8080  LLM-flag=%v MCP-flag=%v", llmFlag, mcpFlag)
	if err := http.ListenAndServe(":8080", nil); err != nil {
		log.Fatal(err)
	}
}

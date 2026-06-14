// extproc-guardrail — a minimal Envoy ext_proc server that inspects the
// request BODY of traffic going through agentgateway and blocks "abusive"
// intents. PoC for tool-/prompt-intent guardrailing.
//
// Two legs, both by inspecting the buffered request body:
//   * LLM  (/openai)      : block if the chat request contains "execute"     ; allow e.g. "teach me"
//   * MCP  (/mcp-mslearn) : block if a tools/call query contains "deploy"    ; allow e.g. "explain"
//
// Mechanism: implements envoy.service.ext_proc.v3.ExternalProcessor. On the
// request-headers phase it asks agentgateway to stream the BUFFERED request
// body (mode_override). On the request-body phase it parses/scans the body and
// either returns an ImmediateResponse(403) to BLOCK, or CONTINUE to ALLOW.
package main

import (
	"encoding/json"
	"io"
	"log"
	"net"
	"strings"

	corev3 "github.com/envoyproxy/go-control-plane/envoy/config/core/v3"
	filterv3 "github.com/envoyproxy/go-control-plane/envoy/extensions/filters/http/ext_proc/v3"
	extprocv3 "github.com/envoyproxy/go-control-plane/envoy/service/ext_proc/v3"
	typev3 "github.com/envoyproxy/go-control-plane/envoy/type/v3"
	"google.golang.org/grpc"
)

// Keyword rules per leg (case-insensitive substring match on the body).
var (
	llmBlock = []string{"execute"}            // LLM: block "execute …", allow "teach me …"
	mcpBlock = []string{"deploy", "execute this"} // MCP: block "deploy …", allow "explain …"
)

type server struct {
	extprocv3.UnimplementedExternalProcessorServer
}

func headerValue(h *corev3.HeaderValue) string {
	if h.GetValue() != "" {
		return h.GetValue()
	}
	return string(h.GetRawValue())
}

// evaluate returns (blocked, leg, reason).
func evaluate(path string, body []byte) (bool, string, string) {
	text := strings.ToLower(string(body))
	p := strings.ToLower(path)

	var leg string
	var keywords []string
	switch {
	case strings.Contains(p, "openai"):
		leg, keywords = "LLM", llmBlock
	case strings.Contains(p, "mcp"):
		leg, keywords = "MCP", mcpBlock
	default:
		leg, keywords = "other", nil
	}

	// Best-effort parse for nicer logs (not required for the decision).
	detail := summarize(leg, body)

	for _, kw := range keywords {
		if strings.Contains(text, kw) {
			return true, leg, "matched blocked keyword \"" + kw + "\"" + detail
		}
	}
	return false, leg, "no blocked keyword" + detail
}

// summarize extracts a short human-readable bit of the payload for logging.
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
			return " [method=" + m.Method + " tool=" + m.Params.Name + " query=\"" + q + "\"]"
		}
	case "LLM":
		var m struct {
			Messages []struct {
				Role    string `json:"role"`
				Content string `json:"content"`
			} `json:"messages"`
		}
		if json.Unmarshal(body, &m) == nil && len(m.Messages) > 0 {
			last := m.Messages[len(m.Messages)-1].Content
			if len(last) > 60 {
				last = last[:60] + "…"
			}
			return " [last_msg=\"" + last + "\"]"
		}
	}
	return ""
}

func (s *server) Process(stream extprocv3.ExternalProcessor_ProcessServer) error {
	var path string
	var bodyBuf []byte
	for {
		req, err := stream.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}

		switch v := req.Request.(type) {

		case *extprocv3.ProcessingRequest_RequestHeaders:
			for _, h := range v.RequestHeaders.GetHeaders().GetHeaders() {
				if h.GetKey() == ":path" {
					path = headerValue(h)
				}
			}
			log.Printf("→ request headers, path=%s (requesting buffered body)", path)
			// Ask agentgateway to send us the full buffered request body next.
			resp := &extprocv3.ProcessingResponse{
				Response: &extprocv3.ProcessingResponse_RequestHeaders{
					RequestHeaders: &extprocv3.HeadersResponse{},
				},
				ModeOverride: &filterv3.ProcessingMode{
					RequestBodyMode: filterv3.ProcessingMode_BUFFERED,
				},
			}
			if err := stream.Send(resp); err != nil {
				return err
			}

		case *extprocv3.ProcessingRequest_RequestBody:
			chunk := v.RequestBody.GetBody()
			eos := v.RequestBody.GetEndOfStream()
			bodyBuf = append(bodyBuf, chunk...)
			log.Printf("→ request body chunk len=%d eos=%v total=%d", len(chunk), eos, len(bodyBuf))

			// Buffer until end-of-stream so we see the whole payload before
			// any of it is forwarded (required to safely BLOCK).
			if !eos {
				stream.Send(&extprocv3.ProcessingResponse{
					Response: &extprocv3.ProcessingResponse_RequestBody{RequestBody: &extprocv3.BodyResponse{}},
				})
				continue
			}

			blocked, leg, reason := evaluate(path, bodyBuf)
			if blocked {
				log.Printf("⛔ BLOCK  leg=%s path=%s — %s", leg, path, reason)
				msg := "Blocked by intent guardrail (" + leg + "): " + reason + "\n"
				if err := stream.Send(&extprocv3.ProcessingResponse{
					Response: &extprocv3.ProcessingResponse_ImmediateResponse{
						ImmediateResponse: &extprocv3.ImmediateResponse{
							Status: &typev3.HttpStatus{Code: typev3.StatusCode_Forbidden},
							Body:   []byte(msg),
						},
					},
				}); err != nil {
					return err
				}
				continue
			}
			log.Printf("✅ ALLOW  leg=%s path=%s — %s", leg, path, reason)
			// Echo the original body back so the upstream receives the full payload.
			if err := stream.Send(&extprocv3.ProcessingResponse{
				Response: &extprocv3.ProcessingResponse_RequestBody{
					RequestBody: &extprocv3.BodyResponse{
						Response: &extprocv3.CommonResponse{
							BodyMutation: &extprocv3.BodyMutation{
								Mutation: &extprocv3.BodyMutation_Body{Body: bodyBuf},
							},
						},
					},
				},
			}); err != nil {
				return err
			}

		case *extprocv3.ProcessingRequest_ResponseHeaders:
			// Not inspecting responses; continue.
			if err := stream.Send(&extprocv3.ProcessingResponse{
				Response: &extprocv3.ProcessingResponse_ResponseHeaders{
					ResponseHeaders: &extprocv3.HeadersResponse{},
				},
			}); err != nil {
				return err
			}

		default:
			// Any other phase: continue without changes.
			if err := stream.Send(&extprocv3.ProcessingResponse{}); err != nil {
				return err
			}
		}
	}
}

func main() {
	lis, err := net.Listen("tcp", ":18080")
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	s := grpc.NewServer()
	extprocv3.RegisterExternalProcessorServer(s, &server{})
	log.Printf("ext_proc guardrail listening on :18080  (LLM block=%v, MCP block=%v)", llmBlock, mcpBlock)
	if err := s.Serve(lis); err != nil {
		log.Fatalf("serve: %v", err)
	}
}

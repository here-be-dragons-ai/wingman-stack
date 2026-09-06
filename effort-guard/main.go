// Command effort-guard is a transparent reverse proxy in front of an mlx-vlm
// server that clamps reasoning_effort values the Qwen3.8 chat template
// rejects.
//
// Why this exists: mlx-vlm does not validate the effort, it forwards it into
// apply_chat_template() as a template kwarg. Qwen3.8's chat_template.jinja
// accepts exactly xhigh, medium and low while thinking is on and calls
// raise_exception() otherwise, which surfaces as HTTP 500:
//
//	{%- if enable_thinking is undefined or enable_thinking is true %}
//	    {%- set resolved_reasoning_effort = reasoning_effort|default('xhigh') %}
//	    {%- if resolved_reasoning_effort not in ('xhigh', 'medium', 'low') %}
//	        {{- raise_exception('Unexpected reasoning effort ...') }}
//
// wingman-agent resolves its main chat loop to "high" whenever no effort is
// pinned (pkg/code/agent/agent.go: effortFor), and lets the model request
// "high" or "max" per subagent. Its clamping is driven by a per-model Efforts
// list in a compiled-in catalog, which is empty for this model, so nothing
// clamps on the client side. Wingman then forwards the value verbatim
// (pkg/provider/openai/util.go: normalizedReasoningEffort).
//
// Pinning WINGMAN_EFFORT and WINGMAN_EFFORT_PLAN covers the common paths; this
// proxy closes the rest so a request can never fail on a value that only names
// an effort level.
package main

import (
	"bytes"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strconv"
	"strings"
)

// supported maps an incoming effort to the nearest level the chat template
// accepts. Ranked values round down, so a request never silently gets more
// reasoning than it asked for. "minimal" is the one exception: it rounds up,
// because low is already the least the template offers while thinking is on.
var supported = map[string]string{
	"minimal": "low",
	"low":     "low",
	"medium":  "medium",
	"high":    "medium",
	"xhigh":   "xhigh",
	"max":     "xhigh",
}

// fallback is the level an effort lands on when the template rejects it and it
// cannot be ranked against the ones above -- "auto", which is in wingman's own
// effortValues, or anything a future client invents.
//
// Dropping the field instead would hand the request to the template's own
// default, and that default is xhigh: the most expensive level, reached by a
// request that never asked for it, on a machine where the expensive level is
// what exhausts the KV cache. medium keeps the round-down promise above.
const fallback = "medium"

// disabled lists the values mlx-vlm turns into enable_thinking=false. They are
// forwarded untouched, because that skips the template branch validating the
// effort altogether. Source: mlx_vlm/server/request_normalization.py.
var disabled = map[string]bool{
	"none":     true,
	"off":      true,
	"disabled": true,
	"false":    true,
	"0":        true,
}

func main() {
	upstream := envOr("UPSTREAM_URL", "http://host.docker.internal:8888")

	target, err := url.Parse(upstream)
	if err != nil {
		log.Fatalf("invalid UPSTREAM_URL %q: %v", upstream, err)
	}

	if target.Scheme == "" || target.Host == "" {
		log.Fatalf("UPSTREAM_URL %q needs a scheme and host, e.g. http://host.docker.internal:8888", upstream)
	}

	verbose := envOr("LOG_REWRITES", "1") != "0"
	addr := ":" + envOr("PORT", "8080")

	proxy := &httputil.ReverseProxy{
		// Flush every write immediately so streamed SSE completions are not
		// buffered into batches.
		FlushInterval: -1,

		Director: func(r *http.Request) {
			r.URL.Scheme = target.Scheme
			r.URL.Host = target.Host
			r.URL.Path = joinPath(target.Path, r.URL.Path)
			r.Host = target.Host
		},

		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			log.Printf("upstream %s %s failed: %v", r.Method, r.URL.Path, err)
			http.Error(w, "effort-guard: upstream unreachable: "+err.Error(), http.StatusBadGateway)
		},
	}

	mux := http.NewServeMux()

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		io.WriteString(w, "ok\n")
	})

	mux.Handle("/", clampEffort(proxy, verbose))

	log.Printf("effort-guard listening on %s, forwarding to %s", addr, target)

	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal(err)
	}
}

// clampEffort rewrites the JSON request body when it carries an unsupported
// effort, and forwards the original bytes untouched in every other case.
func clampEffort(next http.Handler, verbose bool) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.Body == nil || !strings.Contains(r.Header.Get("Content-Type"), "json") {
			next.ServeHTTP(w, r)
			return
		}

		body, err := io.ReadAll(r.Body)
		r.Body.Close()

		if err != nil {
			http.Error(w, "effort-guard: cannot read request body: "+err.Error(), http.StatusBadRequest)
			return
		}

		if rewritten, from, to, changed := rewriteBody(body); changed {
			if verbose {
				log.Printf("%s: reasoning effort %q -> %s", r.URL.Path, from, to)
			}

			body = rewritten
		}

		r.Body = io.NopCloser(bytes.NewReader(body))
		r.ContentLength = int64(len(body))
		r.Header.Set("Content-Length", strconv.Itoa(len(body)))

		next.ServeHTTP(w, r)
	})
}

// rewriteBody clamps reasoning_effort (chat completions dialect) and
// reasoning.effort (responses dialect). changed=false means the caller should
// forward the original body, so a well-formed request is never re-encoded.
func rewriteBody(body []byte) (out []byte, from, to string, changed bool) {
	decoder := json.NewDecoder(bytes.NewReader(body))

	// Keep numeric literals byte-identical when the body is re-encoded;
	// without this, integers would round-trip through float64.
	decoder.UseNumber()

	var payload map[string]any

	if err := decoder.Decode(&payload); err != nil {
		return nil, "", "", false
	}

	from, to, changed = clampField(payload, "reasoning_effort")

	if nested, ok := payload["reasoning"].(map[string]any); ok {
		if f, t, c := clampField(nested, "effort"); c {
			from, to, changed = f, t, true
		}
	}

	if !changed {
		return nil, "", "", false
	}

	out, err := json.Marshal(payload)

	if err != nil {
		return nil, "", "", false
	}

	return out, from, to, true
}

// clampField replaces field in payload when it names an effort the template
// would reject.
func clampField(payload map[string]any, field string) (from, to string, changed bool) {
	raw, ok := payload[field].(string)

	if !ok {
		return "", "", false
	}

	value := strings.ToLower(strings.TrimSpace(raw))

	if value == "" || disabled[value] {
		return "", "", false
	}

	mapped, known := supported[value]

	if !known {
		mapped = fallback
	}

	if mapped == value {
		return "", "", false
	}

	payload[field] = mapped

	return raw, mapped, true
}

func joinPath(base, requested string) string {
	base = strings.TrimSuffix(base, "/")

	if requested == "" {
		return base
	}

	if !strings.HasPrefix(requested, "/") {
		requested = "/" + requested
	}

	return base + requested
}

func envOr(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}

	return fallback
}

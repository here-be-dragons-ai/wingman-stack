package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestRewriteBodyChatCompletions(t *testing.T) {
	tests := []struct {
		name    string
		in      string
		want    string
		changed bool
	}{
		// The value wingman-agent sends whenever no effort is pinned.
		{"high clamps down to medium", `"high"`, "medium", true},
		{"max clamps down to xhigh", `"max"`, "xhigh", true},
		{"minimal clamps up to low", `"minimal"`, "low", true},

		// Already supported by the chat template.
		{"low is left alone", `"low"`, "", false},
		{"medium is left alone", `"medium"`, "", false},
		{"xhigh is left alone", `"xhigh"`, "", false},

		// mlx-vlm turns these into enable_thinking=false, which skips the
		// template branch that validates the effort.
		{"none is left alone", `"none"`, "", false},
		{"off is left alone", `"off"`, "", false},

		// Casing and padding must not defeat the lookup.
		{"HIGH is normalized", `"  HIGH "`, "medium", true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			body := []byte(`{"model":"m","reasoning_effort":` + tc.in + `,"messages":[]}`)

			out, _, _, changed := rewriteBody(body)

			if changed != tc.changed {
				t.Fatalf("changed = %v, want %v", changed, tc.changed)
			}

			if !changed {
				return
			}

			var payload map[string]any
			if err := json.Unmarshal(out, &payload); err != nil {
				t.Fatalf("rewritten body is not valid JSON: %v", err)
			}

			if got := payload["reasoning_effort"]; got != tc.want {
				t.Fatalf("reasoning_effort = %v, want %q", got, tc.want)
			}
		})
	}
}

func TestRewriteBodyResponsesDialect(t *testing.T) {
	body := []byte(`{"model":"m","reasoning":{"effort":"high","summary":"auto"},"input":"hi"}`)

	out, from, to, changed := rewriteBody(body)

	if !changed {
		t.Fatal("expected nested reasoning.effort to be clamped")
	}

	if from != "high" || to != "medium" {
		t.Fatalf("from/to = %q/%q, want high/medium", from, to)
	}

	var payload struct {
		Reasoning struct {
			Effort  string `json:"effort"`
			Summary string `json:"summary"`
		} `json:"reasoning"`
	}

	if err := json.Unmarshal(out, &payload); err != nil {
		t.Fatalf("rewritten body is not valid JSON: %v", err)
	}

	if payload.Reasoning.Effort != "medium" {
		t.Fatalf("reasoning.effort = %q, want medium", payload.Reasoning.Effort)
	}

	// Sibling fields must survive the round-trip.
	if payload.Reasoning.Summary != "auto" {
		t.Fatalf("reasoning.summary = %q, want auto", payload.Reasoning.Summary)
	}
}

// TestRewriteBodyClampsUnrankableEffort covers the values that are neither
// supported nor rankable. Dropping the field would leave the template to apply
// its own default of xhigh -- the most expensive level, for a request that
// never asked for it.
func TestRewriteBodyClampsUnrankableEffort(t *testing.T) {
	// "auto" is in wingman's own effortValues; "turbo" stands for whatever a
	// third-party client invents.
	for _, in := range []string{"auto", "turbo"} {
		t.Run(in, func(t *testing.T) {
			body := []byte(`{"reasoning_effort":"` + in + `"}`)

			out, from, to, changed := rewriteBody(body)

			if !changed || to != fallback {
				t.Fatalf("changed/to = %v/%q, want true/%q", changed, to, fallback)
			}

			if from != in {
				t.Fatalf("from = %q, want %q", from, in)
			}

			var payload map[string]any
			if err := json.Unmarshal(out, &payload); err != nil {
				t.Fatalf("rewritten body is not valid JSON: %v", err)
			}

			if got := payload["reasoning_effort"]; got != fallback {
				t.Fatalf("reasoning_effort = %v, want %q", got, fallback)
			}
		})
	}
}

// TestSupportedRoundsDown pins the invariant the package doc claims, so a new
// entry cannot quietly hand back more reasoning than was asked for.
func TestSupportedRoundsDown(t *testing.T) {
	rank := map[string]int{"minimal": 0, "low": 1, "medium": 2, "high": 3, "xhigh": 4, "max": 5}

	for in, out := range supported {
		// Documented exception: low is the least the template offers while
		// thinking is on, so minimal has nowhere lower to go.
		if in == "minimal" {
			continue
		}

		if rank[out] > rank[in] {
			t.Errorf("supported[%q] = %q rounds up", in, out)
		}
	}

	// The fallback has to be a level the template accepts as-is, or an
	// unrankable effort would still reach the upstream and raise.
	if supported[fallback] != fallback {
		t.Errorf("fallback %q is not a level the template accepts", fallback)
	}
}

func TestRewriteBodyPreservesIntegers(t *testing.T) {
	body := []byte(`{"reasoning_effort":"high","max_tokens":16384,"temperature":0}`)

	out, _, _, changed := rewriteBody(body)

	if !changed {
		t.Fatal("expected a rewrite")
	}

	// json.Number keeps these as written; float64 would render 1.6384e+04.
	if !bytes.Contains(out, []byte(`"max_tokens":16384`)) {
		t.Fatalf("integer literal was mangled: %s", out)
	}

	if !bytes.Contains(out, []byte(`"temperature":0`)) {
		t.Fatalf("zero literal was mangled: %s", out)
	}
}

func TestRewriteBodyIgnoresNonObjects(t *testing.T) {
	if _, _, _, changed := rewriteBody([]byte(`not json`)); changed {
		t.Fatal("non-JSON body must be forwarded untouched")
	}

	if _, _, _, changed := rewriteBody([]byte(`[1,2,3]`)); changed {
		t.Fatal("JSON array body must be forwarded untouched")
	}
}

// TestClampEffortForwardsRewrittenBody checks the middleware end to end,
// including that Content-Length matches the rewritten body.
func TestClampEffortForwardsRewrittenBody(t *testing.T) {
	var seen []byte
	var seenLength int64

	upstream := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen, _ = io.ReadAll(r.Body)
		seenLength = r.ContentLength
	})

	server := httptest.NewServer(clampEffort(upstream, false))
	defer server.Close()

	body := `{"model":"m","reasoning_effort":"high"}`

	resp, err := http.Post(server.URL+"/v1/chat/completions", "application/json", strings.NewReader(body))
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	defer resp.Body.Close()

	if !bytes.Contains(seen, []byte(`"reasoning_effort":"medium"`)) {
		t.Fatalf("upstream saw %s, want a clamped effort", seen)
	}

	if seenLength != int64(len(seen)) {
		t.Fatalf("Content-Length = %d, want %d", seenLength, len(seen))
	}
}

func TestClampEffortLeavesNonJSONAlone(t *testing.T) {
	var seen []byte

	upstream := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen, _ = io.ReadAll(r.Body)
	})

	server := httptest.NewServer(clampEffort(upstream, false))
	defer server.Close()

	resp, err := http.Post(server.URL+"/v1/audio/transcriptions", "multipart/form-data", strings.NewReader("raw-bytes"))
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	defer resp.Body.Close()

	if string(seen) != "raw-bytes" {
		t.Fatalf("upstream saw %q, want the body unchanged", seen)
	}
}

func TestJoinPath(t *testing.T) {
	tests := []struct {
		base, requested, want string
	}{
		{"", "/v1/chat/completions", "/v1/chat/completions"},
		{"/", "/v1/models", "/v1/models"},
		{"/proxy", "/v1/models", "/proxy/v1/models"},
	}

	for _, tc := range tests {
		if got := joinPath(tc.base, tc.requested); got != tc.want {
			t.Errorf("joinPath(%q, %q) = %q, want %q", tc.base, tc.requested, got, tc.want)
		}
	}
}

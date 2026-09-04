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

func TestRewriteBodyDropsUnrankableEffort(t *testing.T) {
	body := []byte(`{"reasoning_effort":"turbo"}`)

	out, _, to, changed := rewriteBody(body)

	if !changed || to != "(dropped)" {
		t.Fatalf("changed/to = %v/%q, want true/(dropped)", changed, to)
	}

	var payload map[string]any
	if err := json.Unmarshal(out, &payload); err != nil {
		t.Fatalf("rewritten body is not valid JSON: %v", err)
	}

	if _, present := payload["reasoning_effort"]; present {
		t.Fatal("unrankable effort should be removed so the template default applies")
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

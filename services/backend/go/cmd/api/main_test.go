package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
)

func TestHealthz(t *testing.T) {
	handler, _ := newAPI()
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d: %s", rec.Code, rec.Body.String())
	}

	var body struct {
		Status string `json:"status"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("failed to decode response body: %v", err)
	}
	if body.Status != "ok" {
		t.Fatalf("expected status %q, got %q", "ok", body.Status)
	}
}

func TestOpenAPIJSON(t *testing.T) {
	handler, _ := newAPI()
	req := httptest.NewRequest(http.MethodGet, "/openapi.json", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/openapi+json" {
		t.Fatalf("expected Content-Type application/openapi+json, got %q", ct)
	}
}

// TestRunOpenAPI covers the `go run ./cmd/api openapi` path make gen-types uses:
// runOpenAPI must succeed and produce the same spec as the HTTP endpoint, without
// starting a listener.
func TestRunOpenAPI(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("failed to create pipe: %v", err)
	}
	origStdout := os.Stdout
	os.Stdout = w
	runErr := runOpenAPI()
	if err := w.Close(); err != nil {
		t.Fatalf("failed to close pipe writer: %v", err)
	}
	os.Stdout = origStdout
	if runErr != nil {
		t.Fatalf("runOpenAPI failed: %v", runErr)
	}

	var doc struct {
		OpenAPI string `json:"openapi"`
	}
	if err := json.NewDecoder(r).Decode(&doc); err != nil {
		t.Fatalf("failed to decode runOpenAPI output: %v", err)
	}
	if doc.OpenAPI == "" {
		t.Fatal("expected a non-empty openapi version field")
	}
}

package api_test

import (
	"bytes"
	"encoding/base64"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"spokenmargins.dev/bridge/internal/api"
	"spokenmargins.dev/bridge/internal/appattest"
	"spokenmargins.dev/bridge/internal/appattest/fakeattest"
	"spokenmargins.dev/bridge/internal/client"
	"spokenmargins.dev/bridge/internal/config"
	"spokenmargins.dev/bridge/internal/store"
)

const appID = "J8SWC6J3VY.com.spokenmargins.native"

// syncBuffer collects log lines written from handler goroutines.
type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

type harness struct {
	t          *testing.T
	ca         *fakeattest.CA
	store      *store.Store
	stateDir   string
	srv        *api.Server
	http       *httptest.Server
	configPath string
	reqLog     *syncBuffer
	abuseLog   *syncBuffer
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	ca, err := fakeattest.NewCA()
	if err != nil {
		t.Fatal(err)
	}
	pool, _ := appattest.PoolFromPEM(ca.RootPEM())
	dir := t.TempDir()
	stateDir := filepath.Join(dir, "state")
	st, err := store.Open(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	public := filepath.Join(dir, "public")
	configPath := filepath.Join(public, "api", "v1", "config.json")
	if err := config.Write(configPath, config.Default()); err != nil {
		t.Fatal(err)
	}
	manifest, err := os.ReadFile("../../../contracts/fixtures/bridge-manifest.example.json")
	if err != nil {
		t.Fatal(err)
	}
	os.MkdirAll(filepath.Join(public, "bridge", "v1"), 0o755)
	os.WriteFile(filepath.Join(public, "bridge", "v1", "manifest.json"), manifest, 0o644)

	h := &harness{t: t, ca: ca, store: st, stateDir: stateDir, configPath: configPath, reqLog: &syncBuffer{}, abuseLog: &syncBuffer{}}
	h.srv = &api.Server{
		Verifier:                &appattest.Verifier{Roots: pool, AppID: appID},
		Store:                   st,
		Config:                  &config.Reader{Path: configPath},
		PublicDir:               public,
		RequestLog:              h.reqLog,
		AbuseLog:                h.abuseLog,
		RequestsPerInstallPerHr: 5,
	}
	h.http = httptest.NewServer(h.srv.Handler())
	t.Cleanup(h.http.Close)
	return h
}

func (h *harness) client() *client.Client {
	d, err := fakeattest.NewDevice(appID)
	if err != nil {
		h.t.Fatal(err)
	}
	return &client.Client{Base: h.http.URL, CA: h.ca, Device: d}
}

func expect(t *testing.T, what string, r client.Response, err error, status int, code string) {
	t.Helper()
	if err != nil {
		t.Fatalf("%s: %v", what, err)
	}
	if r.Status != status || r.Code() != code {
		t.Fatalf("%s: got %s, want HTTP %d error %q", what, r, status, code)
	}
}

// The M1 path end to end: health, config, attest, one attested request,
// replay refused, block one install, kill switch.
func TestSkeletonEndToEnd(t *testing.T) {
	h := newHarness(t)
	c := h.client()

	r, err := c.Get("/api/v1/health")
	expect(t, "health", r, err, 200, "")
	if r.Body["status"] != "ok" {
		t.Fatalf("health body %v", r.Body)
	}

	r, err = c.Get(api.PathConfig)
	expect(t, "config", r, err, 200, "")
	if r.Body["schema"] != config.Schema {
		t.Fatalf("config body %v", r.Body)
	}

	r, err = c.Get(api.PathManifest)
	expect(t, "manifest", r, err, 200, "")

	// Before registering, the server says the key is unknown so the app
	// knows to attest.
	r, err = c.Attested("/api/v1/ping", nil)
	expect(t, "ping before register", r, err, 401, "unknown_key")

	r, err = c.Register()
	expect(t, "register", r, err, 201, "")
	r, err = c.Register()
	expect(t, "register twice", r, err, 409, "already_registered")

	r, err = c.Attested("/api/v1/ping", []byte(`{}`))
	expect(t, "attested ping", r, err, 200, "")

	// Replaying a captured request fails on the counter.
	req, _ := c.Signed("/api/v1/ping", []byte(`{}`))
	body, _ := io.ReadAll(req.Body)
	first, _ := http.NewRequest(req.Method, req.URL.String(), bytes.NewReader(body))
	first.Header = req.Header.Clone()
	r, err = c.Send(first)
	expect(t, "signed ping", r, err, 200, "")
	replay, _ := http.NewRequest(req.Method, req.URL.String(), bytes.NewReader(body))
	replay.Header = req.Header.Clone()
	r, err = c.Send(replay)
	expect(t, "replayed ping", r, err, 401, "invalid_assertion")

	// A signature over one body doesn't cover another.
	req, _ = c.Signed("/api/v1/ping", []byte(`{"a":1}`))
	req.Body = io.NopCloser(strings.NewReader(`{"a":2}`))
	req.ContentLength = 7
	r, err = c.Send(req)
	expect(t, "tampered body", r, err, 401, "invalid_assertion")

	// Blocking one install refuses it and nobody else.
	other := h.client()
	if r, err := other.Register(); err != nil || r.Status != 201 {
		t.Fatalf("second install register: %v %v", r, err)
	}
	if err := h.store.Block(store.Tag(c.Device.KeyID)); err != nil {
		t.Fatal(err)
	}
	r, err = c.Attested("/api/v1/ping", nil)
	expect(t, "blocked install", r, err, 403, "refused")
	r, err = other.Attested("/api/v1/ping", nil)
	expect(t, "unblocked install", r, err, 200, "")

	// Kill switch: attested calls stop, public documents and health don't.
	if _, err := config.Set(h.configPath, config.ServiceAttest, false); err != nil {
		t.Fatal(err)
	}
	r, err = other.Attested("/api/v1/ping", nil)
	expect(t, "ping with attest off", r, err, 503, "disabled")
	fresh := h.client()
	r, err = fresh.Register()
	expect(t, "register with attest off", r, err, 503, "disabled")
	r, err = c.Get("/api/v1/health")
	expect(t, "health with attest off", r, err, 200, "")
	if svc, _ := r.Body["services"].(map[string]any); svc["attest"] != "off" {
		t.Fatalf("health should report attest off: %v", r.Body)
	}
	r, err = c.Get(api.PathConfig)
	expect(t, "config with attest off", r, err, 200, "")
	if serial, _ := r.Body["serial"].(float64); serial != 2 {
		t.Fatalf("kill switch should bump serial to 2: %v", r.Body)
	}

	if _, err := config.Set(h.configPath, config.ServiceAttest, true); err != nil {
		t.Fatal(err)
	}
	r, err = other.Attested("/api/v1/ping", nil)
	expect(t, "ping after revive", r, err, 200, "")

	// Nothing that identifies an install or a client reaches the logs.
	if err := h.srv.Flush(); err != nil {
		t.Fatal(err)
	}
	logs := h.reqLog.String() + h.abuseLog.String()
	forbidden := []string{
		base64.StdEncoding.EncodeToString(c.Device.KeyID),
		base64.StdEncoding.EncodeToString(other.Device.KeyID),
		store.Tag(c.Device.KeyID), store.Tag(other.Device.KeyID),
		"127.0.0.1", "::1", "Go-http-client",
	}
	for _, f := range forbidden {
		if strings.Contains(logs, f) {
			t.Fatalf("logs contain %q:\n%s", f, logs)
		}
	}
	// One summary line per route/status/latency with a count, not one per request.
	if !strings.Contains(h.reqLog.String(), `"route":"/api/v1/ping"`) || !strings.Contains(h.reqLog.String(), `"count":`) {
		t.Fatalf("request log missing expected route lines:\n%s", h.reqLog.String())
	}
}

func TestUnknownPathsAreNotLoggedVerbatim(t *testing.T) {
	h := newHarness(t)
	c := h.client()
	c.Get("/api/v1/users/alice?follow=example.com")
	if h.reqLog.String() != "" {
		t.Fatal("request log must not be written per request")
	}
	h.srv.Flush()
	if s := h.reqLog.String(); strings.Contains(s, "alice") || strings.Contains(s, "example.com") || !strings.Contains(s, `"route":"other"`) {
		t.Fatalf("request log: %s", s)
	}
}

func TestPerInstallRateLimitWritesTagToAbuseLogOnly(t *testing.T) {
	h := newHarness(t)
	c := h.client()
	if r, err := c.Register(); err != nil || r.Status != 201 {
		t.Fatalf("register: %v %v", r, err)
	}
	var last client.Response
	for i := 0; i < 6; i++ {
		last, _ = c.Attested("/api/v1/ping", nil)
	}
	if last.Status != 429 {
		t.Fatalf("sixth request: %s", last)
	}
	tag := store.Tag(c.Device.KeyID)
	if h.abuseLog.String() != "" {
		t.Fatal("abuse lines must wait for the hourly flush")
	}
	h.srv.Flush()
	if !strings.Contains(h.abuseLog.String(), tag) {
		t.Fatalf("abuse log should name the tag so the owner can block it: %s", h.abuseLog.String())
	}
	if strings.Contains(h.reqLog.String(), tag) {
		t.Fatal("request log must not name the tag")
	}
}

func TestClockSkewAndBadAttestation(t *testing.T) {
	h := newHarness(t)
	c := h.client()
	if r, err := c.Register(); err != nil || r.Status != 201 {
		t.Fatalf("register: %v %v", r, err)
	}
	c.Now = func() time.Time { return time.Now().Add(-10 * time.Minute) }
	r, err := c.Attested("/api/v1/ping", nil)
	expect(t, "old timestamp", r, err, 401, "clock_skew")

	// An attestation from a CA other than the trusted root is refused.
	rogueCA, _ := fakeattest.NewCA()
	rogue := h.client()
	rogue.CA = rogueCA
	r, err = rogue.Register()
	expect(t, "rogue CA", r, err, 401, "invalid_attestation")
}

func TestChallengeIsSingleUse(t *testing.T) {
	h := newHarness(t)
	resp, err := http.Post(h.http.URL+"/api/v1/attest/challenge", "application/json", strings.NewReader("{}"))
	if err != nil {
		t.Fatal(err)
	}
	var body struct{ Challenge string }
	decodeJSON(t, resp, &body)
	challenge, _ := base64.StdEncoding.DecodeString(body.Challenge)
	d, _ := fakeattest.NewDevice(appID)
	att, _ := h.ca.Attest(d, challenge, fakeattest.Options{})
	payload := `{"keyId":"` + base64.StdEncoding.EncodeToString(d.KeyID) + `","challenge":"` + body.Challenge + `","attestation":"` + base64.StdEncoding.EncodeToString(att) + `"}`
	for i, want := range []int{201, 400} {
		resp, err := http.Post(h.http.URL+"/api/v1/attest/register", "application/json", strings.NewReader(payload))
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != want {
			t.Fatalf("attempt %d: status %d, want %d", i, resp.StatusCode, want)
		}
	}
}

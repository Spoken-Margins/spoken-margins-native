package api_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"spokenmargins.dev/bridge/internal/config"
	"spokenmargins.dev/bridge/internal/maps"
)

const episodeKey = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"

// stubProvider picks every break it is offered, answers every scene call
// with one title and summary, and counts the calls.
type stubProvider struct {
	mu    sync.Mutex
	calls int
}

func (p *stubProvider) Generator() string { return "stub/model" }

func (p *stubProvider) Generate(ctx context.Context, req maps.Request) (maps.Response, error) {
	p.mu.Lock()
	p.calls++
	p.mu.Unlock()
	text := `{"title":"A part","summary":"One part of a short test episode."}`
	if props, ok := req.Schema["properties"].(map[string]any); ok {
		if breaks, ok := props["breaks"].(map[string]any); ok {
			ids := breaks["items"].(map[string]any)["enum"].([]string)
			data, _ := json.Marshal(map[string][]string{"breaks": ids})
			text = string(data)
		}
	}
	return maps.Response{Text: text, InputTokens: 1000, OutputTokens: 100, Complete: true}, nil
}

func transcriptBody(key string) map[string]any {
	return map[string]any{
		"schema": maps.TranscriptSchema, "episodeKey": key, "durationMs": 180000, "language": "en",
		"segments": []map[string]any{
			{"id": "a", "startMs": 0, "endMs": 60000, "text": "alpha"},
			{"id": "b", "startMs": 60000, "endMs": 120000, "text": "beta"},
			{"id": "c", "startMs": 120000, "endMs": 180000, "text": "gamma"},
		},
	}
}

type mapsHarness struct {
	*harness
	svc      *maps.Service
	provider *stubProvider
	dir      string // the maps directory: maps/, transcripts/ and ledger.json
}

// newMapsHarness is the API harness with maps wired in and switched on.
func newMapsHarness(t *testing.T) *mapsHarness {
	h := newHarness(t)
	dir := filepath.Join(t.TempDir(), "maps")
	store, err := maps.OpenStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	ledger, err := maps.OpenLedger(filepath.Join(dir, "ledger.json"))
	if err != nil {
		t.Fatal(err)
	}
	p := &stubProvider{}
	svc := &maps.Service{
		Store: store, Ledger: ledger, Provider: p,
		Prices: maps.Prices{InputPerMTok: 1, OutputPerMTok: 5}, CapMicroUSD: maps.USDToMicro(10),
	}
	h.srv.MapStore, h.srv.Maps = store, svc
	if _, err := config.Set(h.configPath, config.ServiceMaps, true); err != nil {
		t.Fatal(err)
	}
	return &mapsHarness{harness: h, svc: svc, provider: p, dir: dir}
}

func (h *mapsHarness) post(t *testing.T, body []byte, forwardedFor string) (int, map[string]any) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/api/v1/maps/transcripts", bytes.NewReader(body))
	if forwardedFor != "" {
		req.Header.Set("X-Forwarded-For", forwardedFor)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	decodeJSON(t, resp, &out)
	return resp.StatusCode, out
}

func (h *mapsHarness) postJSON(t *testing.T, v any) (int, map[string]any) {
	t.Helper()
	data, _ := json.Marshal(v)
	return h.post(t, data, "")
}

func (h *mapsHarness) get(t *testing.T, key string) (int, []byte) {
	t.Helper()
	resp, err := http.Get(h.http.URL + "/api/v1/maps/" + key)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, data
}

func TestMapUploadAnswers(t *testing.T) {
	h := newMapsHarness(t)

	bad := map[string]func(map[string]any){
		"short key":      func(b map[string]any) { b["episodeKey"] = episodeKey[:40] },
		"upper-case key": func(b map[string]any) { b["episodeKey"] = strings.ToUpper(episodeKey) },
		"starts repeat": func(b map[string]any) {
			b["segments"].([]map[string]any)[2]["startMs"] = 60000
		},
		"over 3000 segments": func(b map[string]any) {
			var segs []map[string]any
			for i := 0; i < 3001; i++ {
				segs = append(segs, map[string]any{"id": fmt.Sprint(i), "startMs": i, "endMs": i, "text": ""})
			}
			b["segments"] = segs
		},
	}
	for name, change := range bad {
		b := transcriptBody(episodeKey)
		change(b)
		if status, _ := h.postJSON(t, b); status != 400 {
			t.Errorf("%s: HTTP %d, want 400", name, status)
		}
	}
	big := transcriptBody(episodeKey)
	big["segments"].([]map[string]any)[0]["text"] = strings.Repeat("x", 2<<20)
	if status, _ := h.postJSON(t, big); status != 400 {
		t.Errorf("over 2 MB: HTTP %d, want 400", status)
	}

	status, body := h.postJSON(t, transcriptBody(episodeKey))
	if status != 202 || body["status"] != "accepted" {
		t.Fatalf("first upload: HTTP %d %v, want 202", status, body)
	}
	if status, _ := h.get(t, episodeKey); status != 404 {
		t.Fatalf("map before the worker ran: HTTP %d, want 404", status)
	}
	h.svc.ProcessWaiting(context.Background())

	status, data := h.get(t, episodeKey)
	if status != 200 {
		t.Fatalf("map: HTTP %d %s", status, data)
	}
	var m maps.Map
	if err := json.Unmarshal(data, &m); err != nil || m.Schema != maps.MapSchema || m.EpisodeKey != episodeKey ||
		m.Generator != "stub/model" || len(m.Scenes) != 3 || m.Scenes[2].EndMs != 180000 || m.CreatedAt == "" {
		t.Fatalf("map body %s (%v)", data, err)
	}
	if bytes.Contains(data, []byte("alpha")) {
		t.Fatal("map serves transcript text")
	}

	// First upload wins: a second one is 200 and makes no new work.
	status, body = h.postJSON(t, transcriptBody(episodeKey))
	if status != 200 || body["status"] != "mapped" || h.provider.calls != 4 { // the pick and three scenes
		t.Fatalf("second upload: HTTP %d %v, %d calls", status, body, h.provider.calls)
	}
	if status, _ := h.get(t, strings.Repeat("0", 64)); status != 404 {
		t.Fatalf("unknown key: HTTP %d, want 404", status)
	}
	// A slash in the key has to be escaped to reach the handler: a literal
	// "../ledger" is cleaned by the mux and redirected before getMap runs.
	// TestMapKeyCannotEscapeTheMapsDirectory covers the traversal properly.
	if status, _ := h.get(t, "..%2Fledger"); status != 404 {
		t.Fatalf("path in key: HTTP %d, want 404", status)
	}
}

// The key in /api/v1/maps/{key} becomes a file name. A key that decodes to
// "../ledger" or "../transcripts/<key>" would hand out the spend ledger or a
// waiting transcript, so the handler must answer not_found for it. The slash
// is sent escaped (%2F) because a literal "/../" never reaches the handler,
// and the test checks that the answer is the handler's own JSON, not the
// mux's "404 page not found". Both private files exist with real content.
func TestMapKeyCannotEscapeTheMapsDirectory(t *testing.T) {
	h := newMapsHarness(t)
	// Map one episode: the worker writes maps/<key>.json and ledger.json.
	if status, _ := h.postJSON(t, transcriptBody(episodeKey)); status != 202 {
		t.Fatalf("upload: HTTP %d", status)
	}
	h.svc.ProcessWaiting(context.Background())
	// Queue a second transcript the worker never gets to.
	const otherKey = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	if status, _ := h.postJSON(t, transcriptBody(otherKey)); status != 202 {
		t.Fatalf("second upload: HTTP %d", status)
	}

	ledger, err := os.ReadFile(filepath.Join(h.dir, "ledger.json"))
	if err != nil || !bytes.Contains(ledger, []byte("spentMicroUSD")) {
		t.Fatalf("control: ledger file %q, %v", ledger, err)
	}
	// The waiting transcript is in memory only (#1730), so there is no file to reach.
	if !h.svc.Store.HasTranscript(otherKey) {
		t.Fatal("control: the second transcript is not waiting")
	}
	if _, err := os.Stat(filepath.Join(h.dir, "transcripts")); err == nil {
		t.Fatal("a transcripts directory exists on disk")
	}
	if status, data := h.get(t, episodeKey); status != 200 || bytes.Contains(data, []byte("alpha")) {
		t.Fatalf("control: the real map: HTTP %d %s", status, data)
	}

	for name, key := range map[string]string{
		"parent directory":         "..%2Fledger",
		"lower-case escaped dots":  "%2e%2e%2fledger",
		"lower-case escaped slash": "..%2fledger",
		"waiting transcript":       "..%2Ftranscripts%2F" + otherKey,
		"map under a longer path":  "..%2Fmaps%2F" + episodeKey,
		"upper-case episode key":   strings.ToUpper(episodeKey),
		"63 characters":            episodeKey[:63],
		"a .json suffix":           episodeKey + ".json",
		"trailing escaped newline": episodeKey + "%0A",
		"escaped NUL after a key":  episodeKey[:60] + "%00ab",
	} {
		status, data := h.get(t, key)
		if status != 404 || !bytes.Contains(data, []byte(`"error":"not_found"`)) {
			t.Errorf("%s: HTTP %d %q, want the handler's 404 not_found", name, status, data)
		}
		for _, secret := range []string{"spentMicroUSD", "alpha", "calls"} {
			if bytes.Contains(data, []byte(secret)) {
				t.Errorf("%s: answer contains %q: %s", name, secret, data)
			}
		}
	}
}

func TestMapUploadMonthlyCap(t *testing.T) {
	h := newMapsHarness(t)
	h.svc.Ledger.Add(time.Now(), maps.USDToMicro(10))
	status, body := h.postJSON(t, transcriptBody(episodeKey))
	if status != 503 || body["reason"] != "monthly_cap" {
		t.Fatalf("at the cap: HTTP %d %v, want 503 monthly_cap", status, body)
	}
	h.svc.ProcessWaiting(context.Background())
	if h.provider.calls != 0 {
		t.Fatalf("%d provider calls at the cap", h.provider.calls)
	}
}

func TestMapUploadRateLimitPerAddress(t *testing.T) {
	h := newMapsHarness(t)
	h.srv.TrustForwardedFor = true
	bad := []byte(`{}`) // refused as 400, but still counted
	for i := 0; i < 30; i++ {
		if status, _ := h.post(t, bad, "203.0.113.7"); status != 400 {
			t.Fatalf("upload %d: HTTP %d", i+1, status)
		}
	}
	if status, body := h.post(t, bad, "203.0.113.7"); status != 429 || body["error"] != "rate_limited" {
		t.Fatalf("upload 31: HTTP %d %v, want 429", status, body)
	}
	if status, _ := h.post(t, bad, "198.51.100.2"); status != 400 {
		t.Fatalf("another address: HTTP %d, want 400", status)
	}
}

// postFrom sends one refused (empty-object) upload straight to the handler as
// if it came from remoteAddr, with the given X-Forwarded-For, and returns the
// status. Every such upload counts against the sender's hourly limit.
func postFrom(handler http.Handler, remoteAddr, forwardedFor string) int {
	req := httptest.NewRequest(http.MethodPost, "/api/v1/maps/transcripts", strings.NewReader(`{}`))
	req.RemoteAddr = remoteAddr
	if forwardedFor != "" {
		req.Header.Set("X-Forwarded-For", forwardedFor)
	}
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	return rec.Code
}

// The limit is per sender. A sender that can pick its own X-Forwarded-For
// must not get a fresh allowance by changing it: by default the header is
// ignored, and behind Caddy only the hop Caddy appended (the last) counts.
func TestMapUploadLimitIgnoresForwardedForUnlessTrusted(t *testing.T) {
	h := newMapsHarness(t)
	handler := h.srv.Handler() // TrustForwardedFor is off
	for _, peer := range []string{"198.51.100.9:4000", "127.0.0.1:4000"} {
		for i := 0; i < 30; i++ {
			if status := postFrom(handler, peer, fmt.Sprintf("10.0.0.%d", i)); status != 400 {
				t.Fatalf("%s upload %d: HTTP %d, want 400", peer, i+1, status)
			}
		}
		if status := postFrom(handler, peer, "10.0.0.200"); status != 429 {
			t.Fatalf("%s upload 31 with a new X-Forwarded-For: HTTP %d, want 429", peer, status)
		}
	}
}

func TestMapUploadLimitCountsOnlyTheLastForwardedHop(t *testing.T) {
	h := newMapsHarness(t)
	h.srv.TrustForwardedFor = true
	handler := h.srv.Handler()
	const caddy = "127.0.0.1:4000"
	// The sender controls every hop but the last one Caddy appends.
	for i := 0; i < 30; i++ {
		if status := postFrom(handler, caddy, fmt.Sprintf("10.9.8.%d, 203.0.113.7", i)); status != 400 {
			t.Fatalf("upload %d: HTTP %d, want 400", i+1, status)
		}
	}
	for _, header := range []string{"5.6.7.8, 203.0.113.7", "203.0.113.7", " 203.0.113.7 ", "a, b, c, 203.0.113.7"} {
		if status := postFrom(handler, caddy, header); status != 429 {
			t.Errorf("X-Forwarded-For %q: HTTP %d, want 429 (the same sender)", header, status)
		}
	}
	if status := postFrom(handler, caddy, "10.9.8.0, 203.0.113.8"); status != 400 {
		t.Errorf("another last hop: HTTP %d, want 400 (a different sender)", status)
	}
	// Without the header the sender is the peer itself, which is not that sender.
	if status := postFrom(handler, caddy, ""); status != 400 {
		t.Errorf("no X-Forwarded-For: HTTP %d, want 400", status)
	}
}

// Only a loopback peer (Caddy on the same machine) is believed. Anyone who
// reaches the server directly could otherwise name themselves.
func TestMapUploadLimitDoesNotTrustForwardedForFromOtherPeers(t *testing.T) {
	h := newMapsHarness(t)
	h.srv.TrustForwardedFor = true
	handler := h.srv.Handler()
	const stranger = "198.51.100.9:4000"
	for i := 0; i < 30; i++ {
		if status := postFrom(handler, stranger, fmt.Sprintf("10.0.0.%d", i)); status != 400 {
			t.Fatalf("upload %d: HTTP %d, want 400", i+1, status)
		}
	}
	if status := postFrom(handler, stranger, "10.0.0.200"); status != 429 {
		t.Fatalf("upload 31 with a new X-Forwarded-For: HTTP %d, want 429", status)
	}
	if status := postFrom(handler, "198.51.100.10:4000", "10.0.0.1"); status != 400 {
		t.Fatalf("another peer: HTTP %d, want 400", status)
	}
}

func TestMapsSwitchedOffOrUnconfigured(t *testing.T) {
	h := newMapsHarness(t)
	if _, err := config.Set(h.configPath, config.ServiceMaps, false); err != nil {
		t.Fatal(err)
	}
	if status, body := h.postJSON(t, transcriptBody(episodeKey)); status != 503 || body["error"] != "disabled" {
		t.Fatalf("upload with maps off: HTTP %d %v", status, body)
	}
	if status, _ := h.get(t, episodeKey); status != 503 {
		t.Fatalf("fetch with maps off: HTTP %d", status)
	}
	// Health, the config and the manifest are unaffected.
	c := h.client()
	r, err := c.Get("/api/v1/health")
	expect(t, "health with maps off", r, err, 200, "")
	if svc, _ := r.Body["services"].(map[string]any); svc["maps"] != "off" || svc["attest"] != "on" {
		t.Fatalf("health services %v", r.Body["services"])
	}
	r, err = c.Get("/bridge/v1/manifest.json")
	expect(t, "manifest with maps off", r, err, 200, "")
	r, err = c.Register()
	expect(t, "register with maps off", r, err, 201, "")
	r, err = c.Attested("/api/v1/ping", nil)
	expect(t, "ping with maps off", r, err, 200, "")

	// On, but started without an API key: uploads refused, fetches served.
	config.Set(h.configPath, config.ServiceMaps, true)
	h.srv.Maps = nil
	if status, _ := h.postJSON(t, transcriptBody(episodeKey)); status != 503 {
		t.Fatalf("upload without a key: HTTP %d", status)
	}
	if status, _ := h.get(t, episodeKey); status != 404 {
		t.Fatalf("fetch without a key: HTTP %d, want 404", status)
	}
}

// A fresh config with no maps entry, as on the deployed server today, is off.
func TestMapsOffByDefault(t *testing.T) {
	if config.Default().Enabled(config.ServiceMaps) {
		t.Fatal("maps on in the default config")
	}
}

func TestMapRoutesNeverLogTheKey(t *testing.T) {
	h := newMapsHarness(t)
	h.postJSON(t, transcriptBody(episodeKey))
	h.svc.ProcessWaiting(context.Background())
	h.get(t, episodeKey)
	h.get(t, strings.Repeat("1", 64))
	if err := h.srv.Flush(); err != nil {
		t.Fatal(err)
	}
	logs := h.reqLog.String()
	if strings.Contains(logs, episodeKey) || strings.Contains(logs, strings.Repeat("1", 64)) {
		t.Fatalf("request log names an episode key:\n%s", logs)
	}
	if !strings.Contains(logs, `"route":"/api/v1/maps/*"`) || !strings.Contains(logs, `"route":"/api/v1/maps/transcripts"`) {
		t.Fatalf("request log missing map routes:\n%s", logs)
	}
}

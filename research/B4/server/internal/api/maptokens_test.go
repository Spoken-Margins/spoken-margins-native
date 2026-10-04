package api_test

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"spokenmargins.dev/bridge/internal/api"
	"spokenmargins.dev/bridge/internal/config"
	"spokenmargins.dev/bridge/internal/maps"
	"spokenmargins.dev/bridge/internal/tokens"
)

const otherEpisode = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

// newMapTokensHarness has maps and tokens on, and map uploads requiring a
// token unless require is false.
func newMapTokensHarness(t *testing.T, require bool) *mapsHarness {
	h := newMapsHarness(t)
	issuer, err := tokens.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	issuer.KeyBits = 1024 // quick; the tokens package tests the production size
	h.srv.Tokens = issuer
	if _, err := config.Set(h.configPath, config.ServiceTokens, true); err != nil {
		t.Fatal(err)
	}
	if _, err := config.Set(h.configPath, config.ServiceMapUploadToken, require); err != nil {
		t.Fatal(err)
	}
	return h
}

// mintToken runs the phone's side against the issuer directly; the
// issuance route has its own tests.
func mintToken(t *testing.T, issuer *tokens.Issuer, purpose string) []byte {
	t.Helper()
	keys, err := issuer.PublicKeys(time.Now())
	if err != nil {
		t.Fatal(err)
	}
	p, err := tokens.NewPending(rand.Reader, keys[0].Key, purpose)
	if err != nil {
		t.Fatal(err)
	}
	sigs, err := issuer.Sign(time.Now(), keys[0].ID, [][]byte{p.Blinded})
	if err != nil {
		t.Fatal(err)
	}
	tok, err := p.Finish(sigs[0])
	if err != nil {
		t.Fatal(err)
	}
	return tok
}

func authorization(tok []byte) string {
	return `PrivateToken token="` + base64.RawURLEncoding.EncodeToString(tok) + `"`
}

// upload posts a transcript with the given Authorization header ("" for
// none) and returns the status, body and WWW-Authenticate header.
func (h *mapsHarness) upload(t *testing.T, key, auth string) (int, map[string]any, string) {
	t.Helper()
	data, _ := json.Marshal(transcriptBody(key))
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+api.PathMapTranscripts, bytes.NewReader(data))
	if auth != "" {
		req.Header.Set("Authorization", auth)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	decodeJSON(t, resp, &out)
	return resp.StatusCode, out, resp.Header.Get("WWW-Authenticate")
}

func waiting(t *testing.T, h *mapsHarness) int {
	t.Helper()
	n, err := h.svc.Store.CountTranscripts()
	if err != nil {
		t.Fatal(err)
	}
	return n
}

// With the switch off (the default), uploads behave as before: no token
// needed, and a token header, good or not, is ignored.
func TestMapUploadTokenOffByDefault(t *testing.T) {
	if config.Default().Enabled(config.ServiceMapUploadToken) {
		t.Fatal("mapUploadToken on in the default config")
	}
	h := newMapTokensHarness(t, false)
	if status, body, _ := h.upload(t, episodeKey, ""); status != 202 {
		t.Fatalf("upload without a token: HTTP %d %v", status, body)
	}
	if status, body, _ := h.upload(t, otherEpisode, "PrivateToken token=\"!!\""); status != 202 {
		t.Fatalf("upload with a junk token: HTTP %d %v", status, body)
	}
	tok := mintToken(t, h.srv.Tokens, api.TokenPurposeMaps)
	h.upload(t, strings.Repeat("2", 64), authorization(tok))
	if err := h.srv.Tokens.Check(time.Now(), tok, api.TokenPurposeMaps); err != nil {
		t.Fatalf("a token sent while not required was spent: %v", err)
	}
	r, err := h.client().Get("/api/v1/health")
	expect(t, "health", r, err, 200, "")
	if svc, _ := r.Body["services"].(map[string]any); svc["mapUploadToken"] != "off" || svc["maps"] != "on" {
		t.Fatalf("health services %v", r.Body["services"])
	}
}

func TestMapUploadTokenAnswers(t *testing.T) {
	h := newMapTokensHarness(t, true)
	keys, err := h.srv.Tokens.PublicKeys(time.Now())
	if err != nil {
		t.Fatal(err)
	}
	spki, _ := keys[0].SPKI()
	wantChallenge := `PrivateToken challenge="` + base64.URLEncoding.EncodeToString(tokens.Challenge("maps")) +
		`", token-key="` + base64.URLEncoding.EncodeToString(spki) + `"`

	good := mintToken(t, h.srv.Tokens, api.TokenPurposeMaps)
	forged := append([]byte(nil), good...)
	forged[len(forged)-1] ^= 1
	b64 := base64.RawURLEncoding.EncodeToString(good)

	other, err := tokens.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	other.KeyBits = 1024

	for _, c := range []struct {
		name, auth, code string
	}{
		{"no header", "", "token_required"},
		{"another scheme", "Bearer " + b64, "token_required"},
		{"not base64url", `PrivateToken token="` + strings.Repeat("*", 40) + `"`, "token_required"},
		{"no token parameter", `PrivateToken challenge="` + b64 + `"`, "token_required"},
		{"forged", authorization(forged), "token_refused"},
		{"made for another purpose", authorization(mintToken(t, h.srv.Tokens, "bridge")), "token_refused"},
		{"from another server", authorization(mintToken(t, other, api.TokenPurposeMaps)), "token_refused"},
		{"truncated", authorization(good[:60]), "token_refused"},
	} {
		status, body, challenge := h.upload(t, episodeKey, c.auth)
		if status != 401 || body["error"] != c.code {
			t.Errorf("%s: HTTP %d %v, want 401 %s", c.name, status, body, c.code)
		}
		if challenge != wantChallenge {
			t.Errorf("%s: WWW-Authenticate %q, want %q", c.name, challenge, wantChallenge)
		}
	}
	if n := waiting(t, h); n != 0 {
		t.Fatalf("%d transcripts queued by refused uploads", n)
	}

	// A good token, with padding and the scheme in another case, is
	// accepted once. Spent, it's refused for any other episode.
	padded := "privatetoken token=" + base64.URLEncoding.EncodeToString(good)
	if status, body, _ := h.upload(t, episodeKey, padded); status != 202 {
		t.Fatalf("good token: HTTP %d %v", status, body)
	}
	if status, body, _ := h.upload(t, otherEpisode, authorization(good)); status != 401 || body["error"] != "token_refused" {
		t.Fatalf("spent token: HTTP %d %v, want 401 token_refused", status, body)
	}
	if n := waiting(t, h); n != 1 {
		t.Fatalf("%d transcripts waiting, want 1", n)
	}
}

// An upload that turns out to need no work leaves its token spendable, so
// a phone doesn't lose one of its 10 a day to "already mapped".
func TestMapUploadTokenSpentOnlyWhenQueued(t *testing.T) {
	h := newMapTokensHarness(t, true)
	spendable := func(what string, tok []byte) {
		t.Helper()
		if err := h.srv.Tokens.Check(time.Now(), tok, api.TokenPurposeMaps); err != nil {
			t.Fatalf("%s: token no longer spendable: %v", what, err)
		}
	}

	first := mintToken(t, h.srv.Tokens, api.TokenPurposeMaps)
	if status, body, _ := h.upload(t, episodeKey, authorization(first)); status != 202 {
		t.Fatalf("first upload: HTTP %d %v", status, body)
	}
	if !errors.Is(h.srv.Tokens.Check(time.Now(), first, api.TokenPurposeMaps), tokens.ErrSpent) {
		t.Fatal("a queued upload didn't spend its token")
	}

	tok := mintToken(t, h.srv.Tokens, api.TokenPurposeMaps)
	if status, _, _ := h.upload(t, episodeKey, authorization(tok)); status != 202 {
		t.Fatalf("already waiting: HTTP %d", status)
	}
	spendable("already waiting", tok)

	h.svc.ProcessWaiting(context.Background())
	if status, body, _ := h.upload(t, episodeKey, authorization(tok)); status != 200 || body["status"] != "mapped" {
		t.Fatalf("already mapped: HTTP %d %v", status, body)
	}
	spendable("already mapped", tok)

	if _, err := h.svc.Store.Takedown(episodeKey); err != nil {
		t.Fatal(err)
	}
	if status, body, _ := h.upload(t, episodeKey, authorization(tok)); status != 200 || body["status"] != "withdrawn" {
		t.Fatalf("withdrawn: HTTP %d %v", status, body)
	}
	spendable("withdrawn", tok)

	h.svc.MaxWaiting = 1
	h.upload(t, strings.Repeat("3", 64), authorization(mintToken(t, h.srv.Tokens, api.TokenPurposeMaps)))
	if status, body, _ := h.upload(t, otherEpisode, authorization(tok)); status != 503 || body["error"] != "busy" {
		t.Fatalf("queue full: HTTP %d %v", status, body)
	}
	spendable("queue full", tok)
	h.svc.ProcessWaiting(context.Background())

	h.svc.Ledger.Add(time.Now(), maps.USDToMicro(10))
	if status, body, _ := h.upload(t, otherEpisode, authorization(tok)); status != 503 || body["reason"] != "monthly_cap" {
		t.Fatalf("at the cap: HTTP %d %v", status, body)
	}
	spendable("at the cap", tok)
}

// Requiring a token the server can't check refuses uploads rather than
// letting them in.
func TestMapUploadTokenFailsClosed(t *testing.T) {
	h := newMapTokensHarness(t, true)
	tok := mintToken(t, h.srv.Tokens, api.TokenPurposeMaps)
	if _, err := config.Set(h.configPath, config.ServiceTokens, false); err != nil {
		t.Fatal(err)
	}
	if status, body, _ := h.upload(t, episodeKey, authorization(tok)); status != 503 || body["error"] != "disabled" {
		t.Fatalf("tokens off: HTTP %d %v, want 503 disabled", status, body)
	}
	config.Set(h.configPath, config.ServiceTokens, true)
	issuer := h.srv.Tokens
	h.srv.Tokens = nil
	if status, body, _ := h.upload(t, episodeKey, authorization(tok)); status != 503 || body["error"] != "disabled" {
		t.Fatalf("no issuer: HTTP %d %v, want 503 disabled", status, body)
	}
	h.srv.Tokens = issuer
	if n := waiting(t, h); n != 0 {
		t.Fatalf("%d transcripts queued while failing closed", n)
	}
	// Map fetches don't need a token.
	if status, _ := h.get(t, episodeKey); status != 404 {
		t.Fatalf("fetch: HTTP %d, want 404", status)
	}
}

// Many uploads racing with one token queue one transcript.
func TestMapUploadTokenSpendsOnce(t *testing.T) {
	h := newMapTokensHarness(t, true)
	h.srv.MapUploadsPerIPPerHour = 100
	tok := mintToken(t, h.srv.Tokens, api.TokenPurposeMaps)
	const n = 12
	statuses := make([]int, n)
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			key := strings.Repeat(string("456789abcdef"[i]), 64)
			statuses[i], _, _ = h.upload(t, key, authorization(tok))
		}(i)
	}
	wg.Wait()
	accepted := 0
	for i, s := range statuses {
		switch s {
		case 202:
			accepted++
		case 401, 503: // spent by another upload, or every slot busy
		default:
			t.Errorf("upload %d: HTTP %d", i, s)
		}
	}
	if accepted != 1 || waiting(t, h) != 1 {
		t.Fatalf("%d uploads accepted, %d transcripts waiting; want one of each (%v)", accepted, waiting(t, h), statuses)
	}
}

func TestMapUploadTokenNeverLogged(t *testing.T) {
	h := newMapTokensHarness(t, true)
	tok := mintToken(t, h.srv.Tokens, api.TokenPurposeMaps)
	h.upload(t, episodeKey, authorization(tok))
	h.upload(t, otherEpisode, authorization(tok))
	h.upload(t, otherEpisode, "")
	if err := h.srv.Flush(); err != nil {
		t.Fatal(err)
	}
	logs := h.reqLog.String() + h.abuseLog.String()
	parsed, _ := tokens.ParseToken(tok)
	for _, secret := range []string{
		base64.RawURLEncoding.EncodeToString(tok),
		base64.StdEncoding.EncodeToString(tok),
		hex.EncodeToString(parsed.KeyID[:]),
		hex.EncodeToString(parsed.Nonce[:]),
		episodeKey,
	} {
		if strings.Contains(logs, secret) {
			t.Fatalf("logs contain a token, key id, nonce or episode:\n%s", logs)
		}
	}
	if !strings.Contains(logs, `"route":"/api/v1/maps/transcripts","status":401`) ||
		!strings.Contains(logs, `"route":"/api/v1/maps/transcripts","status":202`) {
		t.Fatalf("request log missing the upload route:\n%s", logs)
	}
}

package api_test

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"

	"spokenmargins.dev/bridge/internal/api"
	"spokenmargins.dev/bridge/internal/client"
	"spokenmargins.dev/bridge/internal/config"
	"spokenmargins.dev/bridge/internal/store"
	"spokenmargins.dev/bridge/internal/tokens"
)

// newTokensHarness is the API harness with an issuer wired in and the
// tokens switch on.
func newTokensHarness(t *testing.T) *harness {
	h := newHarness(t)
	issuer, err := tokens.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	issuer.KeyBits = 1024 // quick; the tokens package tests the production size
	h.srv.Tokens = issuer
	h.srv.RequestsPerInstallPerHr = 50 // these tests send more than the base harness's 5
	if _, err := config.Set(h.configPath, config.ServiceTokens, true); err != nil {
		t.Fatal(err)
	}
	return h
}

func getKeys(t *testing.T, h *harness) (int, []byte) {
	t.Helper()
	resp, err := http.Get(h.http.URL + api.PathTokenKeys)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, data
}

// currentKey reads the keys document and returns the signing key, checking
// that its id is the hash of the key it names.
func currentKey(t *testing.T, h *harness) (string, *rsa.PublicKey) {
	t.Helper()
	status, data := getKeys(t, h)
	if status != 200 {
		t.Fatalf("keys: HTTP %d %s", status, data)
	}
	var doc struct {
		Schema    string `json:"schema"`
		TokenType int    `json:"tokenType"`
		Keys      []struct {
			ID        string `json:"tokenKeyId"`
			PublicKey string `json:"publicKey"`
		} `json:"keys"`
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatal(err)
	}
	if doc.Schema != api.TokenKeysSchema || doc.TokenType != 2 || len(doc.Keys) != 1 {
		t.Fatalf("keys document: %s", data)
	}
	der, err := base64.StdEncoding.DecodeString(doc.Keys[0].PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	if sum := sha256.Sum256(der); hex.EncodeToString(sum[:]) != doc.Keys[0].ID {
		t.Fatal("tokenKeyId is not SHA-256 of the public key")
	}
	pub, err := x509.ParsePKIXPublicKey(der)
	if err != nil {
		t.Fatal(err)
	}
	return doc.Keys[0].ID, pub.(*rsa.PublicKey)
}

func issueBody(keyID string, blinded ...[]byte) []byte {
	enc := make([]string, len(blinded))
	for n, b := range blinded {
		enc[n] = base64.StdEncoding.EncodeToString(b)
	}
	data, _ := json.Marshal(map[string]any{"tokenKeyId": keyID, "blindedMessages": enc})
	return data
}

func pending(t *testing.T, pk *rsa.PublicKey, n int) ([]*tokens.Pending, [][]byte) {
	t.Helper()
	ps := make([]*tokens.Pending, n)
	blinded := make([][]byte, n)
	for i := range ps {
		p, err := tokens.NewPending(rand.Reader, pk, "maps")
		if err != nil {
			t.Fatal(err)
		}
		ps[i], blinded[i] = p, p.Blinded
	}
	return ps, blinded
}

func registered(t *testing.T, h *harness) *client.Client {
	t.Helper()
	c := h.client()
	if r, err := c.Register(); err != nil || r.Status != 201 {
		t.Fatalf("register: %v %v", r, err)
	}
	return c
}

// A phone gets three tokens, each spends once, and the server can't tell
// which install a spent token came from because it only ever saw blinded
// values.
func TestTokensIssueAndRedeem(t *testing.T) {
	h := newTokensHarness(t)
	c := registered(t, h)
	keyID, pk := currentKey(t, h)
	ps, blinded := pending(t, pk, 3)

	r, err := c.Attested(api.PathTokens, issueBody(keyID, blinded...))
	expect(t, "issue", r, err, 200, "")
	sigs, _ := r.Body["blindSignatures"].([]any)
	if len(sigs) != 3 || r.Body["tokenKeyId"] != keyID {
		t.Fatalf("issue body: %v", r.Body)
	}
	for n, s := range sigs {
		blindSig, _ := base64.StdEncoding.DecodeString(s.(string))
		tok, err := ps[n].Finish(blindSig)
		if err != nil {
			t.Fatalf("token %d: %v", n, err)
		}
		for _, b := range blinded {
			if strings.Contains(string(tok), string(b)) {
				t.Fatal("a spent token contains the blinded value the server saw")
			}
		}
		if err := h.srv.Tokens.Redeem(h.srv.Now(), tok, "maps"); err != nil {
			t.Fatalf("redeem %d: %v", n, err)
		}
	}
}

func TestTokenIssueAnswers(t *testing.T) {
	h := newTokensHarness(t)
	c := registered(t, h)
	keyID, pk := currentKey(t, h)
	_, blinded := pending(t, pk, 11)

	r, err := c.Attested(api.PathTokens, issueBody(strings.Repeat("ab", 32), blinded[0]))
	expect(t, "another key id", r, err, 409, "stale_key")
	r, err = c.Attested(api.PathTokens, issueBody(keyID, blinded[0][1:]))
	expect(t, "short blinded message", r, err, 400, "bad_request")
	r, err = c.Attested(api.PathTokens, issueBody(keyID, append(blinded[0], 0)))
	expect(t, "long blinded message", r, err, 400, "bad_request")
	tooBig := make([]byte, len(blinded[0]))
	for n := range tooBig {
		tooBig[n] = 0xff
	}
	r, err = c.Attested(api.PathTokens, issueBody(keyID, tooBig))
	expect(t, "blinded message above the modulus", r, err, 400, "bad_request")
	r, err = c.Attested(api.PathTokens, issueBody(keyID, blinded...))
	expect(t, "eleven messages", r, err, 400, "bad_request")
	r, err = c.Attested(api.PathTokens, []byte(`{"tokenKeyId":"`+keyID+`","blindedMessages":["%%%"]}`))
	expect(t, "not base64", r, err, 400, "bad_request")
	r, err = c.Attested(api.PathTokens, issueBody(keyID))
	expect(t, "no messages", r, err, 400, "bad_request")

	// None of those used the day's allowance: ten still come back.
	r, err = c.Attested(api.PathTokens, issueBody(keyID, blinded[:10]...))
	expect(t, "ten tokens", r, err, 200, "")

	if err := h.store.Block(store.Tag(c.Device.KeyID)); err != nil {
		t.Fatal(err)
	}
	r, err = c.Attested(api.PathTokens, issueBody(keyID, blinded[0]))
	expect(t, "blocked install", r, err, 403, "refused")
}

func TestTokenDailyQuotaPerInstall(t *testing.T) {
	h := newTokensHarness(t)
	c := registered(t, h)
	keyID, pk := currentKey(t, h)
	_, blinded := pending(t, pk, 11)

	r, err := c.Attested(api.PathTokens, issueBody(keyID, blinded[:10]...))
	expect(t, "first ten", r, err, 200, "")
	r, err = c.Attested(api.PathTokens, issueBody(keyID, blinded[10]))
	expect(t, "eleventh", r, err, 429, "quota")

	other := registered(t, h)
	r, err = other.Attested(api.PathTokens, issueBody(keyID, blinded[10]))
	expect(t, "another install", r, err, 200, "")

	h.srv.Flush()
	tag := store.Tag(c.Device.KeyID)
	if !strings.Contains(h.abuseLog.String(), tag) || !strings.Contains(h.abuseLog.String(), "token_quota") {
		t.Fatalf("abuse log should name the over-quota install: %s", h.abuseLog.String())
	}
}

func TestTokensSwitchedOff(t *testing.T) {
	if config.Default().Enabled(config.ServiceTokens) {
		t.Fatal("tokens on in the default config")
	}
	h := newTokensHarness(t)
	c := registered(t, h)
	keyID, pk := currentKey(t, h)
	_, blinded := pending(t, pk, 1)
	if _, err := config.Set(h.configPath, config.ServiceTokens, false); err != nil {
		t.Fatal(err)
	}
	r, err := c.Attested(api.PathTokens, issueBody(keyID, blinded...))
	expect(t, "issue with tokens off", r, err, 503, "disabled")
	if status, _ := getKeys(t, h); status != 503 {
		t.Fatalf("keys with tokens off: HTTP %d", status)
	}
	r, err = c.Get("/api/v1/health")
	expect(t, "health", r, err, 200, "")
	if svc, _ := r.Body["services"].(map[string]any); svc["tokens"] != "off" || svc["attest"] != "on" {
		t.Fatalf("health services %v", r.Body["services"])
	}
	r, err = c.Get(api.PathManifest)
	expect(t, "manifest", r, err, 200, "")
	r, err = c.Attested("/api/v1/ping", nil)
	expect(t, "ping", r, err, 200, "")

	// On, but with no issuer wired in: still 503.
	config.Set(h.configPath, config.ServiceTokens, true)
	h.srv.Tokens = nil
	r, err = c.Attested(api.PathTokens, issueBody(keyID, blinded...))
	expect(t, "issue without an issuer", r, err, 503, "disabled")
}

// Everyone gets the same keys document, and the request log names the
// routes but never an install.
func TestTokenKeysAreTheSameForEveryoneAndLogsStayClean(t *testing.T) {
	h := newTokensHarness(t)
	_, a := getKeys(t, h)
	_, b := getKeys(t, h)
	if string(a) != string(b) {
		t.Fatal("two fetches of the keys got different answers")
	}
	c := registered(t, h)
	keyID, pk := currentKey(t, h)
	_, blinded := pending(t, pk, 1)
	c.Attested(api.PathTokens, issueBody(keyID, blinded...))
	h.srv.Flush()
	logs := h.reqLog.String()
	if !strings.Contains(logs, `"route":"/api/v1/tokens"`) || !strings.Contains(logs, `"route":"/api/v1/tokens/keys"`) {
		t.Fatalf("request log missing token routes:\n%s", logs)
	}
	if strings.Contains(logs, store.Tag(c.Device.KeyID)) || strings.Contains(logs, keyID) {
		t.Fatalf("request log names an install or key:\n%s", logs)
	}
}

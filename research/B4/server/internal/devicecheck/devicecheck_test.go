package devicecheck_test

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"spokenmargins.dev/bridge/internal/devicecheck"
)

// apple is a stand-in for Apple's DeviceCheck API at the HTTP boundary. It checks the signed token
// the way Apple does and keeps the two bits per device token.
type apple struct {
	t    *testing.T
	pub  *ecdsa.PublicKey
	mu   sync.Mutex
	bits map[string][2]bool
	// reply overrides the answer when set: status and body.
	status int
	reply  string
	calls  []string
	bodies []string
}

func (a *apple) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	a.mu.Lock()
	defer a.mu.Unlock()
	body, _ := io.ReadAll(r.Body)
	a.calls = append(a.calls, r.URL.Path)
	a.bodies = append(a.bodies, string(body))
	if !a.authorised(r.Header.Get("Authorization")) {
		http.Error(w, "Unable to verify authorization token", http.StatusUnauthorized)
		return
	}
	var in struct {
		Token string `json:"device_token"`
		Tx    string `json:"transaction_id"`
		TS    int64  `json:"timestamp"`
		Bit0  bool   `json:"bit0"`
		Bit1  bool   `json:"bit1"`
	}
	if json.Unmarshal(body, &in) != nil || in.Token == "" || in.Tx == "" || in.TS == 0 {
		http.Error(w, "Missing or badly formatted request", http.StatusBadRequest)
		return
	}
	if a.status != 0 {
		w.WriteHeader(a.status)
		io.WriteString(w, a.reply)
		return
	}
	switch r.URL.Path {
	case "/v1/query_two_bits":
		b, ok := a.bits[in.Token]
		if !ok {
			io.WriteString(w, "Failed to find bit state.")
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"bit0": b[0], "bit1": b[1], "last_update_time": "2026-11"})
	case "/v1/update_two_bits":
		a.bits[in.Token] = [2]bool{in.Bit0, in.Bit1}
	default:
		http.NotFound(w, r)
	}
}

func (a *apple) authorised(h string) bool {
	tok, ok := strings.CutPrefix(h, "Bearer ")
	if !ok {
		return false
	}
	parts := strings.Split(tok, ".")
	if len(parts) != 3 {
		return false
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(sig) != 64 {
		return false
	}
	sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if !ecdsa.Verify(a.pub, sum[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])) {
		return false
	}
	var head struct{ Alg, Kid string }
	var claims struct {
		Iss string
		Iat int64
	}
	hb, _ := base64.RawURLEncoding.DecodeString(parts[0])
	cb, _ := base64.RawURLEncoding.DecodeString(parts[1])
	if json.Unmarshal(hb, &head) != nil || json.Unmarshal(cb, &claims) != nil {
		return false
	}
	return head.Alg == "ES256" && head.Kid == "KEYID12345" && claims.Iss == "TEAMID1234" && claims.Iat > 0
}

func newRig(t *testing.T) (*devicecheck.Client, *apple, *time.Time) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	a := &apple{t: t, pub: &key.PublicKey, bits: map[string][2]bool{}}
	srv := httptest.NewServer(a)
	t.Cleanup(srv.Close)
	now := time.Date(2026, 11, 12, 12, 0, 0, 0, time.UTC)
	return &devicecheck.Client{TeamID: "TEAMID1234", KeyID: "KEYID12345", Key: key, BaseURL: srv.URL, Now: func() time.Time { return now }}, a, &now
}

func TestAFreshDeviceReadsAsZeroThenKeepsWhatWasWritten(t *testing.T) {
	c, _, _ := newRig(t)
	ctx := context.Background()
	if b, err := c.Query(ctx, "tok-a"); err != nil || b.Value() != 0 {
		t.Fatalf("never set: %v %v", b, err)
	}
	for v := uint8(0); v <= 3; v++ {
		if err := c.Update(ctx, "tok-a", devicecheck.BitsOf(v)); err != nil {
			t.Fatalf("update %d: %v", v, err)
		}
		if b, err := c.Query(ctx, "tok-a"); err != nil || b.Value() != v {
			t.Fatalf("after writing %d: %v %v", v, b, err)
		}
	}
	if b, _ := c.Query(ctx, "tok-b"); b.Value() != 0 {
		t.Fatal("another device must not read the first one's bits")
	}
}

func TestBitsRoundTripTheLadderSteps(t *testing.T) {
	for v := uint8(0); v <= 3; v++ {
		if got := devicecheck.BitsOf(v).Value(); got != v {
			t.Errorf("BitsOf(%d).Value() = %d", v, got)
		}
	}
	if b := devicecheck.BitsOf(1); !b.Bit0 || b.Bit1 {
		t.Errorf("strike 1 is bit0 only: %+v", b)
	}
	if b := devicecheck.BitsOf(2); b.Bit0 || !b.Bit1 {
		t.Errorf("strike 2 is bit1 only: %+v", b)
	}
	if b := devicecheck.BitsOf(0b111); b.Value() != 3 {
		t.Errorf("only two bits are read: %+v", b)
	}
}

func TestTheSignedTokenIsReusedForTwentyMinutesThenMadeAgain(t *testing.T) {
	c, _, now := newRig(t)
	ctx := context.Background()
	seen := map[string]bool{}
	capture := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen[r.Header.Get("Authorization")] = true
		io.WriteString(w, "Failed to find bit state.")
	}))
	defer capture.Close()
	c.BaseURL = capture.URL
	hit := func() {
		if _, err := c.Query(ctx, "tok"); err != nil {
			t.Fatal(err)
		}
	}
	hit()
	*now = now.Add(19 * time.Minute)
	hit()
	if len(seen) != 1 {
		t.Fatalf("made a new token inside twenty minutes: %d", len(seen))
	}
	*now = now.Add(2 * time.Minute)
	hit()
	if len(seen) != 2 {
		t.Fatalf("kept an old token past twenty minutes: %d", len(seen))
	}
}

func TestAnswersAreSortedIntoBadTokenAndUnavailable(t *testing.T) {
	c, a, _ := newRig(t)
	ctx := context.Background()
	tests := []struct {
		status int
		want   error
	}{
		{400, devicecheck.ErrBadToken},
		{401, devicecheck.ErrUnavailable}, // the server's own key: the device did nothing wrong
		{403, devicecheck.ErrUnavailable},
		{429, devicecheck.ErrUnavailable},
		{500, devicecheck.ErrUnavailable},
		{503, devicecheck.ErrUnavailable},
	}
	for _, tc := range tests {
		a.status, a.reply = tc.status, "nope"
		if _, err := c.Query(ctx, "tok"); !errors.Is(err, tc.want) {
			t.Errorf("query %d: %v", tc.status, err)
		}
		if err := c.Update(ctx, "tok", devicecheck.BitsOf(1)); !errors.Is(err, tc.want) {
			t.Errorf("update %d: %v", tc.status, err)
		}
	}
	a.status, a.reply = 200, "<html>something else</html>"
	if _, err := c.Query(ctx, "tok"); !errors.Is(err, devicecheck.ErrUnavailable) {
		t.Errorf("unreadable 200: %v", err)
	}
}

func TestTheWrongKeyIsRefusedAndTheTokenIsNeverInAnError(t *testing.T) {
	c, _, _ := newRig(t)
	other, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	c.Key = other
	const secret = "SECRET-DEVICE-TOKEN-1234"
	_, err := c.Query(context.Background(), secret)
	if !errors.Is(err, devicecheck.ErrUnavailable) {
		t.Fatalf("a key Apple does not know: %v", err)
	}
	if strings.Contains(err.Error(), secret) {
		t.Fatal("the device token is in an error")
	}
	c.BaseURL = "http://127.0.0.1:1"
	_, err = c.Query(context.Background(), secret)
	if !errors.Is(err, devicecheck.ErrUnavailable) || strings.Contains(err.Error(), secret) {
		t.Fatalf("no answer: %v", err)
	}
	if _, err := (&devicecheck.Client{}).Query(context.Background(), secret); !errors.Is(err, devicecheck.ErrUnavailable) {
		t.Fatalf("no key configured: %v", err)
	}
}

func TestParseKeyPEM(t *testing.T) {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	good := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	if k, err := devicecheck.ParseKeyPEM(good); err != nil || !k.Equal(key) {
		t.Fatalf("a .p8: %v", err)
	}
	p384, _ := ecdsa.GenerateKey(elliptic.P384(), rand.Reader)
	der384, _ := x509.MarshalPKCS8PrivateKey(p384)
	for name, in := range map[string][]byte{
		"empty":   nil,
		"text":    []byte("not a key"),
		"p384":    pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der384}),
		"garbage": pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: []byte("xx")}),
	} {
		if _, err := devicecheck.ParseKeyPEM(in); err == nil {
			t.Errorf("%s was accepted", name)
		}
	}
}

func TestEveryRequestCarriesATransactionAndATimestamp(t *testing.T) {
	c, a, _ := newRig(t)
	ctx := context.Background()
	c.Query(ctx, "tok")
	c.Query(ctx, "tok")
	var first, second struct {
		Tx string `json:"transaction_id"`
		TS int64  `json:"timestamp"`
	}
	json.Unmarshal([]byte(a.bodies[0]), &first)
	json.Unmarshal([]byte(a.bodies[1]), &second)
	if first.Tx == "" || first.Tx == second.Tx || first.TS != time.Date(2026, 11, 12, 12, 0, 0, 0, time.UTC).UnixMilli() {
		t.Fatalf("%+v %+v", first, second)
	}
}

package api_test

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"spokenmargins.dev/bridge/internal/appattest/fakeattest"
)

// Limits and expiries of the unauthenticated endpoints, driven by a clock the
// test moves. Each of these guards is invisible in a normal run: nothing
// reaches 30 requests, waits out a TTL or sends an oversized body unless the
// test makes it.

type stepClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *stepClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *stepClock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(d)
}

// withClock replaces the harness server's time source and returns the clock.
func withClock(h *harness) *stepClock {
	clock := &stepClock{t: time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)}
	h.srv.Now = clock.Now
	return clock
}

func postRaw(t *testing.T, url string, body []byte) (int, string) {
	t.Helper()
	resp, err := http.Post(url, "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	var out struct {
		Error     string
		Challenge string
	}
	decodeJSON(t, resp, &out)
	if out.Error != "" {
		return resp.StatusCode, out.Error
	}
	return resp.StatusCode, out.Challenge
}

func TestChallengeEndpointLimitsOneAddressPerHour(t *testing.T) {
	h := newHarness(t)
	clock := withClock(h)
	url := h.http.URL + "/api/v1/attest/challenge"
	for i := 0; i < 30; i++ {
		if status, got := postRaw(t, url, []byte(`{}`)); status != 200 {
			t.Fatalf("challenge %d: HTTP %d %s", i+1, status, got)
		}
	}
	if status, got := postRaw(t, url, []byte(`{}`)); status != 429 || got != "rate_limited" {
		t.Fatalf("challenge 31: HTTP %d %s, want 429 rate_limited", status, got)
	}
	// The allowance comes back an hour after the window opened, not before,
	// and then it is a whole new allowance, not one more request.
	clock.Advance(time.Hour - time.Second)
	if status, _ := postRaw(t, url, []byte(`{}`)); status != 429 {
		t.Fatalf("a second before the hour is up: HTTP %d, want 429", status)
	}
	clock.Advance(time.Second)
	for i := 0; i < 30; i++ {
		if status, got := postRaw(t, url, []byte(`{}`)); status != 200 {
			t.Fatalf("challenge %d of the next hour: HTTP %d %s", i+1, status, got)
		}
	}
	if status, _ := postRaw(t, url, []byte(`{}`)); status != 429 {
		t.Fatalf("challenge 31 of the next hour: HTTP %d, want 429", status)
	}
}

func TestRegisterEndpointLimitsOneAddressPerHour(t *testing.T) {
	h := newHarness(t)
	withClock(h)
	url := h.http.URL + "/api/v1/attest/register"
	for i := 0; i < 30; i++ {
		if status, got := postRaw(t, url, []byte(`{}`)); status != 400 || got != "bad_request" {
			t.Fatalf("register %d: HTTP %d %s, want 400 bad_request", i+1, status, got)
		}
	}
	if status, got := postRaw(t, url, []byte(`{}`)); status != 429 || got != "rate_limited" {
		t.Fatalf("register 31: HTTP %d %s, want 429 rate_limited", status, got)
	}
}

// A challenge is good for five minutes. It is not an open-ended ticket.
func TestChallengeExpiresAfterFiveMinutes(t *testing.T) {
	h := newHarness(t)
	clock := withClock(h)
	register := func(wait time.Duration) (int, string) {
		t.Helper()
		_, b64 := postRaw(t, h.http.URL+"/api/v1/attest/challenge", []byte(`{}`))
		challenge, err := base64.StdEncoding.DecodeString(b64)
		if err != nil || len(challenge) != 32 {
			t.Fatalf("challenge %q: %v", b64, err)
		}
		d, err := fakeattest.NewDevice(appID)
		if err != nil {
			t.Fatal(err)
		}
		att, err := h.ca.Attest(d, challenge, fakeattest.Options{})
		if err != nil {
			t.Fatal(err)
		}
		clock.Advance(wait)
		payload := fmt.Sprintf(`{"keyId":%q,"challenge":%q,"attestation":%q}`,
			base64.StdEncoding.EncodeToString(d.KeyID), b64, base64.StdEncoding.EncodeToString(att))
		return postRaw(t, h.http.URL+"/api/v1/attest/register", []byte(payload))
	}

	if status, got := register(5*time.Minute - time.Second); status != 201 {
		t.Fatalf("register just inside the TTL: HTTP %d %s, want 201", status, got)
	}
	if status, got := register(5*time.Minute + time.Second); status != 400 || got != "challenge_expired" {
		t.Fatalf("register just past the TTL: HTTP %d %s, want 400 challenge_expired", status, got)
	}
}

// The server holds at most 10000 unexpired challenges and says "busy" past
// that, so a flood of challenge requests from many addresses can't grow its
// memory without bound; expired ones stop counting.
func TestChallengeTableIsBounded(t *testing.T) {
	if testing.Short() {
		t.Skip("fills the 10000-entry table: about a second, nine under -race")
	}
	h := newHarness(t)
	clock := withClock(h)
	h.srv.TrustForwardedFor = true
	handler := h.srv.Handler()
	ask := func(i int) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, "/api/v1/attest/challenge", strings.NewReader(`{}`))
		req.RemoteAddr = "127.0.0.1:4000"
		req.Header.Set("X-Forwarded-For", fmt.Sprintf("10.%d.%d.%d", i>>16&255, i>>8&255, i&255))
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		return rec
	}
	for i := 0; i < 10000; i++ {
		if rec := ask(i); rec.Code != 200 {
			t.Fatalf("challenge %d: HTTP %d %s", i+1, rec.Code, rec.Body)
		}
	}
	if rec := ask(10000); rec.Code != 503 || !strings.Contains(rec.Body.String(), `"busy"`) {
		t.Fatalf("challenge 10001: HTTP %d %s, want 503 busy", rec.Code, rec.Body)
	}
	clock.Advance(5*time.Minute + time.Second)
	if rec := ask(10001); rec.Code != 200 {
		t.Fatalf("after the challenges expired: HTTP %d %s, want 200", rec.Code, rec.Body)
	}
}

func TestAssertionTimestampMustBeWithinFiveMinutesEitherWay(t *testing.T) {
	h := newHarness(t)
	clock := withClock(h)
	c := h.client()
	if r, err := c.Register(); err != nil || r.Status != 201 {
		t.Fatalf("register: %v %v", r, err)
	}
	for _, tc := range []struct {
		name   string
		offset time.Duration
		status int
		code   string
	}{
		{"five minutes old", -5 * time.Minute, 200, ""},
		{"five minutes and a second old", -5*time.Minute - time.Second, 401, "clock_skew"},
		{"five minutes ahead", 5 * time.Minute, 200, ""},
		{"five minutes and a second ahead", 5*time.Minute + time.Second, 401, "clock_skew"},
		{"ten minutes ahead", 10 * time.Minute, 401, "clock_skew"},
	} {
		c.Now = func() time.Time { return clock.Now().Add(tc.offset) }
		r, err := c.Attested("/api/v1/ping", nil)
		expect(t, tc.name, r, err, tc.status, tc.code)
	}
}

// Both unauthenticated JSON endpoints read their bodies through a cap. The
// oversized bodies below are otherwise well formed, so without the cap they
// are read to the end and answered by a later check with a different code.
func TestOversizedBodiesAreRefusedBeforeTheyAreParsed(t *testing.T) {
	h := newHarness(t)
	withClock(h)

	keyID := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32))
	registerBody := func(attestationBytes int) []byte {
		return []byte(fmt.Sprintf(`{"keyId":%q,"challenge":"","attestation":%q}`, keyID, strings.Repeat("A", attestationBytes)))
	}
	url := h.http.URL + "/api/v1/attest/register"
	// Control: a small body of this shape is read and refused by the challenge check.
	if status, got := postRaw(t, url, registerBody(100)); status != 400 || got != "challenge_expired" {
		t.Fatalf("control, small register body: HTTP %d %s, want 400 challenge_expired", status, got)
	}
	if status, got := postRaw(t, url, registerBody(33<<10)); status != 400 || got != "bad_request" {
		t.Fatalf("33 KB register body: HTTP %d %s, want 400 bad_request", status, got)
	}

	attested := func(bodyBytes int) (int, string) {
		t.Helper()
		req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/api/v1/ping", bytes.NewReader(bytes.Repeat([]byte{' '}, bodyBytes)))
		req.Header.Set("X-SM-Key-Id", keyID)
		req.Header.Set("X-SM-Assertion", base64.StdEncoding.EncodeToString([]byte("not checked before the body is read")))
		req.Header.Set("X-SM-Time", fmt.Sprint(h.srv.Now().Unix()))
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		var out struct{ Error string }
		decodeJSON(t, resp, &out)
		return resp.StatusCode, out.Error
	}
	if status, got := attested(100); status != 401 || got != "unknown_key" {
		t.Fatalf("control, small attested body: HTTP %d %s, want 401 unknown_key", status, got)
	}
	if status, got := attested(65 << 10); status != 413 || got != "too_large" {
		t.Fatalf("65 KB attested body: HTTP %d %s, want 413 too_large", status, got)
	}
}

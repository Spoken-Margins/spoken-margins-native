package api_test

import (
	"net/url"
	"strconv"
	"testing"

	"spokenmargins.dev/bridge/internal/api"
)

// The bytes an app signs for an attested request. The test client signs with
// api.ClientData too, so any change to this function applies to both sides of
// every other test and cancels out; only a literal can notice it. The Swift
// client (not written yet) must produce exactly these bytes, and the
// assertion is worth nothing if it doesn't cover each of these four parts.
func TestClientDataBytesAreFixed(t *testing.T) {
	const want = "spokenmargins-assertion-v1\nPOST\n/api/v1/ping\n1700000000\n" +
		"44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a" // SHA-256 of "{}"
	if got := string(api.ClientData("POST", "/api/v1/ping", 1700000000, []byte("{}"))); got != want {
		t.Fatalf("ClientData = %q\nwant         %q", got, want)
	}
	// Each part changes the bytes.
	base := string(api.ClientData("POST", "/api/v1/ping", 1700000000, []byte("{}")))
	for name, other := range map[string][]byte{
		"method": api.ClientData("PUT", "/api/v1/ping", 1700000000, []byte("{}")),
		"path":   api.ClientData("POST", "/api/v1/tokens", 1700000000, []byte("{}")),
		"time":   api.ClientData("POST", "/api/v1/ping", 1700000001, []byte("{}")),
		"body":   api.ClientData("POST", "/api/v1/ping", 1700000000, []byte("{ }")),
	} {
		if string(other) == base {
			t.Errorf("changing the %s doesn't change what is signed", name)
		}
	}
}

// An assertion made for one request can't be spent on another: sent to a
// different path, or with a different time, the signature no longer matches.
// (A different body is covered by TestSkeletonEndToEnd. The method can't be
// varied through the handler, since the mux routes only POST to attested
// endpoints; TestClientDataBytesAreFixed pins it.)
func TestAssertionIsBoundToItsPathAndTime(t *testing.T) {
	h := newTokensHarness(t)
	c := h.client()
	if r, err := c.Register(); err != nil || r.Status != 201 {
		t.Fatalf("register: %v %v", r, err)
	}
	body := []byte(`{}`)

	// Control: the request as signed is accepted.
	r, err := c.Attested("/api/v1/ping", body)
	expect(t, "ping as signed", r, err, 200, "")

	// Signed for /api/v1/ping, sent to /api/v1/tokens.
	req, err := c.Signed("/api/v1/ping", body)
	if err != nil {
		t.Fatal(err)
	}
	if req.URL, err = url.Parse(h.http.URL + api.PathTokens); err != nil {
		t.Fatal(err)
	}
	r, err = c.Send(req)
	expect(t, "assertion for another path", r, err, 401, "invalid_assertion")

	// The time header moved by one second, well inside the allowed skew.
	req, err = c.Signed("/api/v1/ping", body)
	if err != nil {
		t.Fatal(err)
	}
	unix, err := strconv.ParseInt(req.Header.Get(api.HeaderTime), 10, 64)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set(api.HeaderTime, strconv.FormatInt(unix+1, 10))
	r, err = c.Send(req)
	expect(t, "assertion with the time shifted by a second", r, err, 401, "invalid_assertion")

	// Neither refusal used up the install's counter: the next honest request works.
	r, err = c.Attested("/api/v1/ping", body)
	expect(t, "ping after the refusals", r, err, 200, "")
}

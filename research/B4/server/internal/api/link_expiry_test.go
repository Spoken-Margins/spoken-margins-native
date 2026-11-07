package api_test

import (
	"strings"
	"testing"
	"time"

	"spokenmargins.dev/bridge/internal/links"
)

// The packet says which day the link stops working (#2168), at day precision: no time, no creation moment.
// A cross-origin page can read it only if the server exposes it.
func TestLinkPacketExpiryDayHeader(t *testing.T) {
	_, _, h, id := corsLinks(t, webApp)
	want := time.Date(2026, 10, 30, 0, 0, 0, 0, time.UTC).Add(links.Lifetime).Format("2006-01-02")

	w := corsRequest(h, "GET", "/l/"+id+"/packet", webApp, nil, nil, "")
	if w.Code != 200 {
		t.Fatalf("status %d", w.Code)
	}
	if got := w.Header().Get("X-SM-Link-Expires"); got != want {
		t.Errorf("X-SM-Link-Expires %q, want %q", got, want)
	}
	if got := w.Header().Get("Access-Control-Expose-Headers"); got != "X-SM-Link-Expires" {
		t.Errorf("Access-Control-Expose-Headers %q", got)
	}

	// Without CORS (same origin, apps) the header is there and nothing is exposed.
	w = corsRequest(h, "GET", "/l/"+id+"/packet", "", nil, nil, "")
	if got := w.Header().Get("X-SM-Link-Expires"); got != want {
		t.Errorf("same-origin X-SM-Link-Expires %q, want %q", got, want)
	}
	noCORS(t, "same-origin", w)

	// An unlisted origin is not told it can read it.
	w = corsRequest(h, "GET", "/l/"+id+"/packet", "https://evil.example", nil, nil, "")
	noCORS(t, "unlisted", w)

	// The preview never carries it, and neither does a failure.
	w = corsRequest(h, "GET", "/l/"+id+"/preview", webApp, nil, nil, "")
	if w.Header().Get("X-SM-Link-Expires") != "" {
		t.Error("preview carries the expiry header")
	}
	w = corsRequest(h, "GET", "/l/"+strings.Repeat("0", 32)+"/packet", webApp, nil, nil, "")
	if w.Header().Get("X-SM-Link-Expires") != "" {
		t.Error("an unknown link carries the expiry header")
	}
}

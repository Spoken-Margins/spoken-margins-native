package api_test

// Tests for the security review on #2986 (#2988), and the siblings of each
// finding.

import (
	"net/http"
	"net/url"
	"testing"

	"spokenmargins.dev/bridge/internal/api"
	"spokenmargins.dev/bridge/internal/config"
)

// reviewRelayHarness is newHarness with testRelay and the relay switch on.
func reviewRelayHarness(t *testing.T) (*harness, string) {
	t.Helper()
	h := newHarness(t)
	rl, target := testRelay(t, "<rss/>")
	h.srv.Relay = rl
	if _, err := config.Set(h.configPath, config.ServiceRelay, true); err != nil {
		t.Fatal(err)
	}
	return h, target
}

func reviewGet(t *testing.T, h *harness, target string, headers map[string]string) int {
	t.Helper()
	req, _ := http.NewRequest("GET", h.http.URL+api.PathRelay+"?url="+url.QueryEscape(target), nil)
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	return resp.StatusCode
}

// Finding 4: a cross-site <img> is a no-cors GET with no Origin.
func TestReviewRefusesNoCorsBrowserFetch(t *testing.T) {
	h, target := reviewRelayHarness(t)
	code := reviewGet(t, h, target, map[string]string{"Sec-Fetch-Mode": "no-cors", "Sec-Fetch-Site": "cross-site", "Sec-Fetch-Dest": "image"})
	if code == 200 {
		t.Fatal("a cross-site no-cors subresource request was relayed")
	}
}

// A page on another site can't spend a visitor's hourly budget either: a
// refused caller is answered before the limit counts it.
func TestRefusedCallersDoNotSpendTheBudget(t *testing.T) {
	h, target := reviewRelayHarness(t)
	h.srv.RelayPerIPPerHour = 1
	for _, hdr := range []map[string]string{{}, {"Origin": "https://evil.example"}} {
		for i := 0; i < 3; i++ {
			if code := reviewGet(t, h, target, hdr); code != 403 {
				t.Fatalf("refused caller %v: %d, want 403", hdr, code)
			}
		}
	}
	if code := reviewGet(t, h, target, map[string]string{"Origin": webOrigin}); code != 200 {
		t.Fatalf("the web app after refusals: %d, want 200", code)
	}
}

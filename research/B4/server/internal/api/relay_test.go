package api_test

import (
	"io"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"testing"

	"spokenmargins.dev/bridge/internal/api"
	"spokenmargins.dev/bridge/internal/config"
	"spokenmargins.dev/bridge/internal/relay"
)

const webOrigin = "https://web.spokenmargins.test"

// testRelay may reach one httptest server on 127.0.0.1; every other rule is
// the production one (internal/relay tests cover those).
func testRelay(t *testing.T, body string) (*relay.Relay, string) {
	t.Helper()
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/rss+xml")
		io.WriteString(w, body)
	}))
	t.Cleanup(up.Close)
	u, _ := url.Parse(up.URL)
	port, _ := strconv.Atoi(u.Port())
	loop := netip.MustParseAddr("127.0.0.1")
	return &relay.Relay{
		Origins: []string{webOrigin},
		Ports:   []int{port},
		Allowed: func(a netip.Addr) bool { return a == loop },
	}, up.URL + "/private-feed-path.xml?token=listener-secret"
}

func relayGet(t *testing.T, h *harness, target string) (int, string) {
	t.Helper()
	req, _ := http.NewRequest("GET", h.http.URL+api.PathRelay+"?url="+url.QueryEscape(target), nil)
	req.Header.Set("Origin", webOrigin)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

// The relay is off until the owner's switch is on and the server was started
// with web app origins, like links.
func TestRelayIsOffUntilSwitchedOnAndConfigured(t *testing.T) {
	h := newHarness(t)
	rl, target := testRelay(t, "<rss/>")

	h.srv.Relay = rl
	if code, body := relayGet(t, h, target); code != 503 || !strings.Contains(body, "disabled") {
		t.Fatalf("default config: %d %s", code, body)
	}
	if _, err := config.Set(h.configPath, config.ServiceRelay, true); err != nil {
		t.Fatal(err)
	}
	h.srv.Relay = nil
	if code, _ := relayGet(t, h, target); code != 503 {
		t.Fatalf("switch on, no relay: %d", code)
	}
	h.srv.Relay = &relay.Relay{}
	if code, _ := relayGet(t, h, target); code != 503 {
		t.Fatalf("switch on, no origins: %d", code)
	}
	h.srv.Relay = rl
	if code, body := relayGet(t, h, target); code != 200 || body != "<rss/>" {
		t.Fatalf("switch on: %d %s", code, body)
	}
	if _, err := config.Set(h.configPath, config.ServiceRelay, false); err != nil {
		t.Fatal(err)
	}
	if code, _ := relayGet(t, h, target); code != 503 {
		t.Fatalf("switch off again: %d", code)
	}
}

// A per-client hourly limit like linkWindow, and the request log names the
// route but never the URL.
func TestRelayRateLimitAndLog(t *testing.T) {
	h := newHarness(t)
	rl, target := testRelay(t, "<rss/>")
	h.srv.Relay = rl
	h.srv.RelayPerIPPerHour = 2
	if _, err := config.Set(h.configPath, config.ServiceRelay, true); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if code, _ := relayGet(t, h, target); code != 200 {
			t.Fatalf("fetch %d: %d", i, code)
		}
	}
	if code, body := relayGet(t, h, target); code != 429 || !strings.Contains(body, "rate_limited") {
		t.Fatalf("third fetch: %d %s", code, body)
	}
	if code, _ := relayGet(t, h, "http://10.0.0.1/"); code != 429 {
		t.Fatalf("the limit counts refusals too: %d", code)
	}
	if err := h.srv.Flush(); err != nil {
		t.Fatal(err)
	}
	log := h.reqLog.String() + h.abuseLog.String()
	if !strings.Contains(log, `"route":"`+api.PathRelay+`"`) {
		t.Fatalf("relay route not counted: %s", log)
	}
	for _, leak := range []string{"private-feed-path", "listener-secret", "127.0.0.1", "url="} {
		if strings.Contains(log, leak) {
			t.Fatalf("log holds %q: %s", leak, log)
		}
	}
}

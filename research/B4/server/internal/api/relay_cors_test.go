package api_test

import (
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"

	"spokenmargins.dev/bridge/internal/api"
	"spokenmargins.dev/bridge/internal/config"
	"spokenmargins.dev/bridge/internal/relay"
)

// A browser hides the status and body of any cross-origin answer without
// Access-Control-Allow-Origin, so the web app read "switched off" as
// "unreachable" (#3018). Every answer to a listed origin carries it, refusals
// included; an answer to any other origin carries none.

type corsUpstream struct {
	base    string // http://127.0.0.1:<port>
	port    int
	entered chan struct{}
	release chan struct{}
}

func newCorsUpstream(t *testing.T) *corsUpstream {
	t.Helper()
	c := &corsUpstream{entered: make(chan struct{}, 1), release: make(chan struct{})}
	mux := http.NewServeMux()
	mux.HandleFunc("/feed.xml", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/rss+xml")
		io.WriteString(w, "<rss/>")
	})
	mux.HandleFunc("/status", func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "gone", http.StatusInternalServerError)
	})
	mux.HandleFunc("/image", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "image/png")
		io.WriteString(w, "png")
	})
	mux.HandleFunc("/big", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/rss+xml")
		io.WriteString(w, strings.Repeat("x", 4096))
	})
	mux.HandleFunc("/loop", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/loop", http.StatusFound)
	})
	mux.HandleFunc("/slow", func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-r.Context().Done():
		case <-time.After(5 * time.Second):
		}
	})
	mux.HandleFunc("/hold", func(w http.ResponseWriter, r *http.Request) {
		c.entered <- struct{}{}
		select {
		case <-c.release:
		case <-r.Context().Done():
		}
		w.Header().Set("Content-Type", "application/rss+xml")
		io.WriteString(w, "<rss/>")
	})
	up := httptest.NewServer(mux)
	t.Cleanup(up.Close)
	u, _ := url.Parse(up.URL)
	c.base = up.URL
	c.port, _ = strconv.Atoi(u.Port())
	return c
}

// closedPort is a loopback port nothing listens on.
func closedPort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := l.Addr().(*net.TCPAddr).Port
	l.Close()
	return port
}

func corsHarness(t *testing.T, up *corsUpstream, dead int, on bool) *harness {
	t.Helper()
	h := newHarness(t)
	loop := netip.MustParseAddr("127.0.0.1")
	h.srv.Relay = &relay.Relay{
		Origins:       []string{webOrigin},
		Ports:         []int{up.port, dead},
		Allowed:       func(a netip.Addr) bool { return a == loop },
		Timeout:       300 * time.Millisecond,
		MaxBytes:      1024,
		MaxConcurrent: 1,
	}
	if on {
		if _, err := config.Set(h.configPath, config.ServiceRelay, true); err != nil {
			t.Fatal(err)
		}
	}
	return h
}

type corsAnswer struct {
	status int
	code   string
	allow  string
	vary   string
}

func corsGet(t *testing.T, h *harness, target, origin string) corsAnswer {
	t.Helper()
	req, _ := http.NewRequest("GET", h.http.URL+api.PathRelay+"?url="+url.QueryEscape(target), nil)
	if origin != "" {
		req.Header.Set("Origin", origin)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var body struct{ Error string }
	b, _ := io.ReadAll(resp.Body)
	json.Unmarshal(b, &body)
	return corsAnswer{resp.StatusCode, body.Error, resp.Header.Get("Access-Control-Allow-Origin"), resp.Header.Get("Vary")}
}

func wantListed(t *testing.T, name string, got corsAnswer, status int, code string) {
	t.Helper()
	if got.status != status || got.code != code {
		t.Fatalf("%s: got %d %q, want %d %q", name, got.status, got.code, status, code)
	}
	if got.allow != webOrigin {
		t.Errorf("%s: Access-Control-Allow-Origin = %q, want %q", name, got.allow, webOrigin)
	}
	if !strings.Contains(got.vary, "Origin") {
		t.Errorf("%s: Vary = %q, want Origin", name, got.vary)
	}
}

func TestRelaySwitchedOffIsReadableByAListedOrigin(t *testing.T) {
	up := newCorsUpstream(t)
	h := corsHarness(t, up, closedPort(t), false)
	wantListed(t, "switched off", corsGet(t, h, up.base+"/feed.xml", webOrigin), 503, "disabled")
}

func TestRelayRateLimitIsReadableByAListedOrigin(t *testing.T) {
	up := newCorsUpstream(t)
	h := corsHarness(t, up, closedPort(t), true)
	h.srv.RelayPerIPPerHour = 1
	wantListed(t, "first", corsGet(t, h, up.base+"/feed.xml", webOrigin), 200, "")
	wantListed(t, "rate limited", corsGet(t, h, up.base+"/feed.xml", webOrigin), 429, "rate_limited")
}

func TestRelayRefusalsAndUpstreamFailuresAreReadableByAListedOrigin(t *testing.T) {
	up := newCorsUpstream(t)
	dead := closedPort(t)
	h := corsHarness(t, up, dead, true)
	for _, tc := range []struct {
		name, target string
		status       int
		code         string
	}{
		{"success", up.base + "/feed.xml", 200, ""},
		{"bad url", "not a url", 400, "bad_url"},
		{"blocked port", "http://127.0.0.1:1/", 403, "port_refused"},
		{"blocked address", "http://10.0.0.1:" + strconv.Itoa(up.port) + "/", 403, "address_refused"},
		{"upstream status", up.base + "/status", 502, "upstream_status"},
		{"type refused", up.base + "/image", 502, "type_refused"},
		{"too large", up.base + "/big", 502, "too_large"},
		{"too many redirects", up.base + "/loop", 502, "too_many_redirects"},
		{"unreachable", "http://127.0.0.1:" + strconv.Itoa(dead) + "/feed.xml", 502, "upstream_unreachable"},
		{"timeout", up.base + "/slow", 504, "timeout"},
	} {
		wantListed(t, tc.name, corsGet(t, h, tc.target, webOrigin), tc.status, tc.code)
	}
}

func TestRelayBusyIsReadableByAListedOrigin(t *testing.T) {
	up := newCorsUpstream(t)
	h := corsHarness(t, up, closedPort(t), true)
	h.srv.Relay.Timeout = 5 * time.Second
	done := make(chan int, 1)
	go func() {
		req, _ := http.NewRequest("GET", h.http.URL+api.PathRelay+"?url="+url.QueryEscape(up.base+"/hold"), nil)
		req.Header.Set("Origin", webOrigin)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			done <- 0
			return
		}
		resp.Body.Close()
		done <- resp.StatusCode
	}()
	select {
	case <-up.entered:
	case <-time.After(5 * time.Second):
		t.Fatal("the held fetch never reached the upstream")
	}
	wantListed(t, "busy", corsGet(t, h, up.base+"/feed.xml", webOrigin), 503, "busy")
	close(up.release)
	if status := <-done; status != 200 {
		t.Fatalf("held fetch: %d", status)
	}
}

// An unlisted origin, or none, is told nothing a browser would let a script
// read: no Access-Control-Allow-Origin on any answer, on or off.
func TestRelayAnswersToUnlistedOriginsCarryNoCORS(t *testing.T) {
	up := newCorsUpstream(t)
	dead := closedPort(t)
	for _, on := range []bool{false, true} {
		h := corsHarness(t, up, dead, on)
		for _, origin := range []string{"https://evil.example", webOrigin + ".evil.example", "null", ""} {
			got := corsGet(t, h, up.base+"/feed.xml", origin)
			want := 403
			if !on {
				want = 503
			}
			if got.status != want {
				t.Errorf("on=%v origin %q: status %d, want %d", on, origin, got.status, want)
			}
			if got.allow != "" {
				t.Errorf("on=%v origin %q: Access-Control-Allow-Origin = %q, want none", on, origin, got.allow)
			}
			if !strings.Contains(got.vary, "Origin") {
				t.Errorf("on=%v origin %q: Vary = %q, want Origin", on, origin, got.vary)
			}
		}
	}
}

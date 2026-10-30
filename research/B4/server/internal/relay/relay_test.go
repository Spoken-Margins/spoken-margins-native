package relay_test

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"spokenmargins.dev/bridge/internal/relay"
)

// fakeDNS answers from a table, so no test touches real DNS. A name not in
// the table fails to resolve.
func fakeDNS(table map[string][]string) func(context.Context, string) ([]netip.Addr, error) {
	return func(_ context.Context, host string) ([]netip.Addr, error) {
		var out []netip.Addr
		for _, s := range table[host] {
			out = append(out, netip.MustParseAddr(s))
		}
		if len(out) == 0 {
			return nil, errors.New("no such host")
		}
		return out, nil
	}
}

// upstream starts an httptest server and a relay that may reach it: the
// relay allows 127.0.0.1 (only) plus every public address, and the server's port
// plus 80 and 443. Everything else keeps the production rules, so a
// redirect from the test server to a private address is still refused.
func upstream(t *testing.T, h http.Handler) (*httptest.Server, *relay.Relay, int) {
	t.Helper()
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	u, _ := url.Parse(srv.URL)
	port, _ := strconv.Atoi(u.Port())
	r := &relay.Relay{
		Origins: []string{"https://web.spokenmargins.test"},
		Ports:   []int{80, 443, port},
		Allowed: func(a netip.Addr) bool { return a == testServerAddr || relay.PublicAddr(a) },
		Lookup:  fakeDNS(map[string][]string{"feed.test": {"127.0.0.1"}, "private.test": {"10.0.0.7"}}),
	}
	return srv, r, port
}

var testServerAddr = netip.MustParseAddr("127.0.0.1")

func wantCode(t *testing.T, what string, err error, code string) {
	t.Helper()
	var re *relay.Error
	if !errors.As(err, &re) {
		t.Fatalf("%s: got %v, want relay error %q", what, err, code)
	}
	if re.Code != code {
		t.Fatalf("%s: got %q, want %q", what, re.Code, code)
	}
}

// Every address rule, on the production relay (no overrides). None of these
// may reach the network: literals are refused when parsed, and names
// resolve through the fake table.
func TestRefusesURLsBeforeFetching(t *testing.T) {
	r := &relay.Relay{
		Lookup: fakeDNS(map[string][]string{
			"localhost":       {"127.0.0.1", "::1"},
			"rebind.example":  {"93.184.215.14", "10.0.0.1"},
			"metadata.google": {"169.254.169.254"},
			"v6only.example":  {"fd00::1"},
			"mapped.example":  {"::ffff:192.168.0.1"},
		}),
	}
	cases := []struct{ url, code string }{
		// Not a URL the relay takes.
		{"", "bad_url"},
		{"/relative/path", "bad_url"},
		{"ftp://example.com/feed.xml", "bad_url"},
		{"file:///etc/passwd", "bad_url"},
		{"gopher://example.com/", "bad_url"},
		{"javascript:alert(1)", "bad_url"},
		{"http:example.com", "bad_url"},
		{"http://user:pass@example.com/feed", "bad_url"},
		{"https://example.com/" + strings.Repeat("a", relay.MaxURLLength), "bad_url"},
		// Ports other than 80 and 443.
		{"http://example.com:8080/feed", "port_refused"},
		{"https://example.com:22/", "port_refused"},
		{"http://example.com:0/", "bad_url"},
		// IPv4 literals.
		{"http://127.0.0.1/", "address_refused"},
		{"http://127.255.255.254/", "address_refused"},
		{"http://10.0.0.1/", "address_refused"},
		{"http://172.16.5.4/", "address_refused"},
		{"http://192.168.1.1/", "address_refused"},
		{"http://169.254.169.254/latest/meta-data/", "address_refused"},
		{"http://0.0.0.0/", "address_refused"},
		{"http://100.100.100.100/", "address_refused"}, // Tailscale's resolver
		{"http://224.0.0.1/", "address_refused"},
		{"http://255.255.255.255/", "address_refused"},
		// IPv6 literals.
		{"http://[::1]/", "address_refused"},
		{"http://[::]/", "address_refused"},
		{"http://[::ffff:127.0.0.1]/", "address_refused"},
		{"http://[::ffff:a9fe:a9fe]/", "address_refused"}, // 169.254.169.254, mapped
		{"http://[fe80::1]/", "address_refused"},
		{"http://[fe80::1%25en0]/", "address_refused"},
		{"http://[fc00::1]/", "address_refused"},
		{"http://[fd12:3456::1]/", "address_refused"},
		{"http://[64:ff9b::a00:1]/", "address_refused"}, // NAT64 of 10.0.0.1
		{"http://[2002:7f00:1::]/", "address_refused"},  // 6to4 of 127.0.0.1
		{"http://[ff02::1]/", "address_refused"},
		// Spellings some resolvers read as 127.0.0.1.
		{"http://2130706433/", "bad_url"},
		{"http://0x7f000001/", "bad_url"},
		{"http://0x7f.0.0.1/", "bad_url"},
		{"http://127.1/", "bad_url"},
		{"http://0177.0.0.1/", "bad_url"},
		{"http://017700000001/", "bad_url"},
	}
	for _, c := range cases {
		_, err := r.Fetch(context.Background(), c.url)
		wantCode(t, c.url, err, c.code)
	}

	// Names are checked after resolution, and every answer must be public.
	names := []struct{ url, code string }{
		{"http://localhost/", "address_refused"},
		{"http://rebind.example/", "address_refused"},
		{"http://metadata.google/computeMetadata/v1/", "address_refused"},
		{"https://v6only.example/", "address_refused"},
		{"http://mapped.example/", "address_refused"},
		{"http://does-not-resolve.example/", "upstream_unreachable"},
	}
	for _, c := range names {
		_, err := r.Fetch(context.Background(), c.url)
		wantCode(t, c.url, err, c.code)
	}
}

func TestPublicAddr(t *testing.T) {
	for _, s := range []string{"93.184.215.14", "1.1.1.1", "2606:4700:4700::1111", "::ffff:8.8.8.8"} {
		if !relay.PublicAddr(netip.MustParseAddr(s)) {
			t.Errorf("%s should be public", s)
		}
	}
	for _, s := range []string{"127.0.0.1", "10.1.2.3", "100.64.0.1", "169.254.1.1", "::1", "fe80::1", "fc00::1", "::", "0.0.0.0", "198.18.0.1", "2001:db8::1"} {
		if relay.PublicAddr(netip.MustParseAddr(s)) {
			t.Errorf("%s should be refused", s)
		}
	}
}

func TestDefaults(t *testing.T) {
	if relay.DefaultTimeout != 10*time.Second || relay.DefaultMaxBytes != 5<<20 || relay.DefaultMaxRedirects != 5 {
		t.Fatalf("defaults changed: %v %d %d", relay.DefaultTimeout, relay.DefaultMaxBytes, relay.DefaultMaxRedirects)
	}
}

const rss = `<?xml version="1.0"?><rss version="2.0"><channel><title>Fixture</title></channel></rss>`

// The happy path: the body and content type come back, the listener's
// cookies and headers don't go out, and the publisher's cookies don't come
// back. The name resolves through the relay's own lookup, so the dial went
// to the checked address (the system resolver doesn't know feed.test).
func TestRelaysAFeedAndNothingElse(t *testing.T) {
	var sawCookie, sawReferer, sawForwarded atomic.Bool
	_, r, port := upstream(t, http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		sawCookie.Store(req.Header.Get("Cookie") != "")
		sawReferer.Store(req.Header.Get("Referer") != "")
		sawForwarded.Store(req.Header.Get("X-Forwarded-For") != "")
		http.SetCookie(w, &http.Cookie{Name: "track", Value: "me"})
		w.Header().Set("Content-Type", "application/rss+xml; charset=utf-8; foo=bar")
		w.Header().Set("X-Upstream", "secret")
		w.Write([]byte(rss))
	}))
	front := httptest.NewServer(r)
	defer front.Close()

	req, _ := http.NewRequest("GET", front.URL+"/?url="+url.QueryEscape("http://feed.test:"+strconv.Itoa(port)+"/feed.xml"), nil)
	req.Header.Set("Origin", "https://web.spokenmargins.test")
	req.Header.Set("Cookie", "session=listener")
	req.Header.Set("Referer", "https://web.spokenmargins.test/library")
	req.Header.Set("X-Forwarded-For", "203.0.113.9")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body := make([]byte, len(rss)+10)
	n, _ := resp.Body.Read(body)
	if resp.StatusCode != 200 || string(body[:n]) != rss {
		t.Fatalf("got %d %q", resp.StatusCode, body[:n])
	}
	if ct := resp.Header.Get("Content-Type"); ct != "application/rss+xml; charset=utf-8" {
		t.Errorf("content type %q", ct)
	}
	if got := resp.Header.Get("Access-Control-Allow-Origin"); got != "https://web.spokenmargins.test" {
		t.Errorf("ACAO %q", got)
	}
	for _, h := range []string{"Set-Cookie", "X-Upstream"} {
		if resp.Header.Get(h) != "" {
			t.Errorf("upstream header %s came back", h)
		}
	}
	if resp.Header.Get("Cache-Control") != "no-store" || !strings.Contains(resp.Header.Get("Content-Security-Policy"), "sandbox") {
		t.Errorf("missing no-store or sandbox: %v", resp.Header)
	}
	if sawCookie.Load() || sawReferer.Load() || sawForwarded.Load() {
		t.Errorf("listener headers reached upstream: cookie=%v referer=%v xff=%v", sawCookie.Load(), sawReferer.Load(), sawForwarded.Load())
	}
}

func TestRefusesOtherOrigins(t *testing.T) {
	var hits atomic.Int32
	srv, r, _ := upstream(t, http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		hits.Add(1)
		w.Header().Set("Content-Type", "text/html")
		w.Write([]byte("<p>hi</p>"))
	}))
	front := httptest.NewServer(r)
	defer front.Close()
	req, _ := http.NewRequest("GET", front.URL+"/?url="+url.QueryEscape(srv.URL), nil)
	req.Header.Set("Origin", "https://evil.example")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var body map[string]string
	json.NewDecoder(resp.Body).Decode(&body)
	resp.Body.Close()
	if resp.StatusCode != 403 || body["error"] != "origin_refused" || resp.Header.Get("Access-Control-Allow-Origin") != "" {
		t.Fatalf("got %d %v %v", resp.StatusCode, body, resp.Header)
	}
	if hits.Load() != 0 {
		t.Fatal("a refused origin still fetched upstream")
	}
}

// Refusals that need an upstream: redirects, size, type, status and time.
func TestRefusesWhatUpstreamSends(t *testing.T) {
	release := make(chan struct{})
	mux := http.NewServeMux()
	mux.HandleFunc("/metadata", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "http://169.254.169.254/latest/meta-data/", http.StatusFound)
	})
	mux.HandleFunc("/to-v6-loopback", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "http://[::1]/", http.StatusFound)
	})
	mux.HandleFunc("/to-private-name", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "http://private.test/", http.StatusMovedPermanently)
	})
	mux.HandleFunc("/to-port", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "http://feed.test:6379/", http.StatusFound)
	})
	mux.HandleFunc("/to-file", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "file:///etc/passwd", http.StatusFound)
	})
	mux.HandleFunc("/loop/", func(w http.ResponseWriter, r *http.Request) {
		n, _ := strconv.Atoi(strings.TrimPrefix(r.URL.Path, "/loop/"))
		if n == 0 {
			w.Header().Set("Content-Type", "text/html")
			w.Write([]byte("<p>end</p>"))
			return
		}
		http.Redirect(w, r, "/loop/"+strconv.Itoa(n-1), http.StatusFound)
	})
	mux.HandleFunc("/big", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		w.Write(make([]byte, relay.DefaultMaxBytes+1))
	})
	mux.HandleFunc("/big-declared", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		w.Header().Set("Content-Length", strconv.Itoa(relay.DefaultMaxBytes+1))
		w.Write([]byte("<p>"))
	})
	mux.HandleFunc("/exact", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		w.Write(make([]byte, relay.DefaultMaxBytes))
	})
	for path, ct := range map[string]string{"/png": "image/png", "/json": "application/json", "/js": "text/javascript", "/none": ""} {
		mux.HandleFunc(path, func(w http.ResponseWriter, r *http.Request) {
			w.Header()["Content-Type"] = []string{ct}
			w.Write([]byte("x"))
		})
	}
	mux.HandleFunc("/404", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		w.WriteHeader(404)
	})
	mux.HandleFunc("/slow", func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-release:
		case <-r.Context().Done():
		}
	})
	mux.HandleFunc("/slow-body", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/rss+xml")
		w.WriteHeader(200)
		w.(http.Flusher).Flush()
		select {
		case <-release:
		case <-r.Context().Done():
		}
	})
	srv, r, _ := upstream(t, mux)
	defer close(release)
	r.Timeout = 300 * time.Millisecond

	cases := []struct{ path, code string }{
		{"/metadata", "address_refused"},
		{"/to-v6-loopback", "address_refused"},
		{"/to-private-name", "address_refused"},
		{"/to-port", "port_refused"},
		{"/to-file", "bad_url"},
		{"/loop/6", "too_many_redirects"},
		{"/big", "too_large"},
		{"/big-declared", "too_large"},
		{"/png", "type_refused"},
		{"/json", "type_refused"},
		{"/js", "type_refused"},
		{"/none", "type_refused"},
		{"/404", "upstream_status"},
		{"/slow", "timeout"},
		{"/slow-body", "timeout"},
	}
	for _, c := range cases {
		start := time.Now()
		_, err := r.Fetch(context.Background(), srv.URL+c.path)
		wantCode(t, c.path, err, c.code)
		if d := time.Since(start); d > 5*time.Second {
			t.Errorf("%s took %v", c.path, d)
		}
	}

	// The limits are limits, not off-by-one refusals.
	if res, err := r.Fetch(context.Background(), srv.URL+"/loop/5"); err != nil || string(res.Body) != "<p>end</p>" {
		t.Fatalf("five redirects should be followed: %v", err)
	}
	if res, err := r.Fetch(context.Background(), srv.URL+"/exact"); err != nil || len(res.Body) != relay.DefaultMaxBytes {
		t.Fatalf("a body of exactly the cap should pass: %v", err)
	}
}

// The redirect check runs on the dial itself, so a hop is refused even if
// a name only turns private on its second lookup.
func TestEveryConnectionIsResolvedAndChecked(t *testing.T) {
	var lookups atomic.Int32
	_, r, port := upstream(t, http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.URL.Path == "/" {
			http.Redirect(w, req, "/again", http.StatusFound)
			return
		}
		w.Header().Set("Content-Type", "text/html")
		w.Write([]byte("ok"))
	}))
	r.Lookup = func(_ context.Context, host string) ([]netip.Addr, error) {
		if lookups.Add(1) == 1 {
			return []netip.Addr{netip.MustParseAddr("127.0.0.1")}, nil
		}
		return []netip.Addr{netip.MustParseAddr("10.0.0.1")}, nil
	}
	_, err := r.Fetch(context.Background(), "http://rebind.test:"+strconv.Itoa(port)+"/")
	wantCode(t, "rebinding on the redirect", err, "address_refused")
	if lookups.Load() != 2 {
		t.Fatalf("want one lookup per connection, got %d", lookups.Load())
	}
}

func TestBusyWhenFull(t *testing.T) {
	release := make(chan struct{})
	started := make(chan struct{}, 1)
	srv, r, _ := upstream(t, http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		started <- struct{}{}
		<-release
		w.Header().Set("Content-Type", "text/html")
	}))
	r.MaxConcurrent = 1
	done := make(chan error)
	go func() { _, err := r.Fetch(context.Background(), srv.URL); done <- err }()
	<-started
	_, err := r.Fetch(context.Background(), srv.URL)
	wantCode(t, "second fetch", err, "busy")
	close(release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

package relay_test

// Tests for the security review on #2986 (#2988), and the siblings of each
// finding.

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"strconv"
	"sync/atomic"
	"testing"

	"spokenmargins.dev/bridge/internal/relay"
)

// Finding 2: Go's client sets Referer to the previous URL on every redirect
// hop, so a private feed's token would reach the next host.
func TestReviewRedirectSendsNoReferer(t *testing.T) {
	var gotReferer string
	mux := http.NewServeMux()
	mux.HandleFunc("/private-feed.xml", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/cdn/feed.xml", http.StatusFound)
	})
	mux.HandleFunc("/cdn/feed.xml", func(w http.ResponseWriter, r *http.Request) {
		gotReferer = r.Header.Get("Referer")
		w.Header().Set("Content-Type", "application/rss+xml")
		w.Write([]byte("<rss/>"))
	})
	srv, r, _ := upstream(t, mux)
	if _, err := r.Fetch(context.Background(), srv.URL+"/private-feed.xml?token=listener-secret"); err != nil {
		t.Fatal(err)
	}
	if gotReferer != "" {
		t.Fatalf("redirect target received Referer %q", gotReferer)
	}
}

// Finding 2's class: anything Go adds or copies onto a redirect hop. The hop
// carries only the fixed headers the first request did.
func TestRedirectHopCarriesOnlyTheFixedHeaders(t *testing.T) {
	var got http.Header
	mux := http.NewServeMux()
	mux.HandleFunc("/a", func(w http.ResponseWriter, r *http.Request) {
		http.SetCookie(w, &http.Cookie{Name: "track", Value: "me"})
		http.Redirect(w, r, "/b", http.StatusMovedPermanently)
	})
	mux.HandleFunc("/b", func(w http.ResponseWriter, r *http.Request) {
		got = r.Header.Clone()
		w.Header().Set("Content-Type", "text/html")
		w.Write([]byte("<p/>"))
	})
	srv, r, _ := upstream(t, mux)
	if _, err := r.Fetch(context.Background(), srv.URL+"/a?token=listener-secret"); err != nil {
		t.Fatal(err)
	}
	for name := range got {
		switch name {
		case "User-Agent", "Accept", "Accept-Encoding", "Connection":
		default:
			t.Errorf("redirect hop carried %s: %q", name, got.Get(name))
		}
	}
}

// Finding 5: special-purpose IPv6 ranges judged public.
func TestReviewSpecialPurposeV6(t *testing.T) {
	for _, s := range []string{"::ffff:0:7f00:1", "fec0::1", "2001:10::1", "2001:20::1"} {
		if relay.PublicAddr(netip.MustParseAddr(s)) {
			t.Errorf("%s judged public", s)
		}
	}
}

// Finding 5's class: every block in the IANA special-purpose registries
// (iana-ipv4-special-registry, iana-ipv6-special-registry) that is not
// globally reachable, plus deprecated ones, one address each.
func TestPublicAddrRefusesSpecialPurposeRegistries(t *testing.T) {
	for _, s := range []string{
		"0.1.2.3", "192.0.0.9", "192.0.2.1", "192.88.99.1", "198.51.100.1", "203.0.113.1",
		"240.0.0.1", "255.255.255.255", "224.0.0.1",
		"::ffff:0:a00:1", // SIIT, IPv4-translated 10.0.0.1
		"::a00:1",        // IPv4-compatible
		"64:ff9b::a00:1", // NAT64
		"64:ff9b:1::1",   // local-use NAT64
		"100::1",         // discard
		"100:0:0:1::1",   // dummy prefix
		"2001::1",        // Teredo
		"2001:2::1",      // benchmarking
		"2001:30::1",     // drone remote ID
		"2001:db8::1",    // documentation
		"2002:a00:1::1",  // 6to4 around 10.0.0.1
		"3fff::1",        // documentation
		"5f00::1",        // SRv6 SIDs
		"fc00::1", "fd12::1",
		"fec0::1", // site-local
		"fe80::1", "ff02::1", "ff05::1", "ff0e::1",
	} {
		if relay.PublicAddr(netip.MustParseAddr(s)) {
			t.Errorf("%s judged public", s)
		}
	}
	for _, s := range []string{"2001:4860:4860::8888", "2a00:1450::1", "2620:fe::fe", "8.8.4.4", "::ffff:1.1.1.1"} {
		if !relay.PublicAddr(netip.MustParseAddr(s)) {
			t.Errorf("%s should be public", s)
		}
	}
}

func relayStatus(t *testing.T, target string, headers map[string]string) (int, map[string]string, http.Header) {
	t.Helper()
	req, _ := http.NewRequest("GET", target, nil)
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var body map[string]string
	json.NewDecoder(resp.Body).Decode(&body)
	return resp.StatusCode, body, resp.Header
}

func countingFeed(t *testing.T) (*httptest.Server, *relay.Relay, *atomic.Int32) {
	var hits atomic.Int32
	srv, r, _ := upstream(t, http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		hits.Add(1)
		w.Header().Set("Content-Type", "application/rss+xml")
		w.Write([]byte("<rss/>"))
	}))
	return srv, r, &hits
}

// Finding 4: a cross-site <img> or <script> sends no Origin, so the origin
// check never ran. Every request must name a listed origin.
func TestRefusesRequestsWithNoListedOrigin(t *testing.T) {
	feed, r, hits := countingFeed(t)
	front := httptest.NewServer(r)
	defer front.Close()
	target := front.URL + "/?url=" + url.QueryEscape(feed.URL+"/feed.xml")
	for _, h := range []map[string]string{
		{"Sec-Fetch-Mode": "no-cors", "Sec-Fetch-Site": "cross-site", "Sec-Fetch-Dest": "image"},
		{},
		{"Origin": "null"},
		{"Origin": "https://web.spokenmargins.test.evil.example"},
	} {
		code, body, hdr := relayStatus(t, target, h)
		if code != 403 || body["error"] != "origin_refused" || hdr.Get("Access-Control-Allow-Origin") != "" {
			t.Errorf("headers %v: got %d %v", h, code, body)
		}
		if hdr.Get("Cache-Control") != "no-store" || hdr.Get("Vary") != "Origin" {
			t.Errorf("headers %v: refusal headers %v", h, hdr)
		}
	}
	if hits.Load() != 0 {
		t.Fatal("a request with no listed origin still fetched upstream")
	}
}

// Finding 5 (the review's item 6): the server's own public address passes
// PublicAddr, so ?url= could point back at the relay. The relay's own
// User-Agent marks a nested request whatever host name or address it used,
// even one that forges a listed Origin.
func TestRefusesItsOwnRequests(t *testing.T) {
	feed, r, hits := countingFeed(t)
	front := httptest.NewServer(r)
	defer front.Close()
	code, body, _ := relayStatus(t, front.URL+"/?url="+url.QueryEscape(feed.URL+"/feed.xml"),
		map[string]string{"Origin": "https://web.spokenmargins.test", "User-Agent": relay.UserAgent})
	if code != 403 || body["error"] != "loop_refused" {
		t.Fatalf("got %d %v", code, body)
	}
	if hits.Load() != 0 {
		t.Fatal("a nested relay request still fetched upstream")
	}
}

// End to end: the relay pointed at itself fetches nothing.
func TestRelayPointedAtItselfDoesNotNest(t *testing.T) {
	feed, r, hits := countingFeed(t)
	front := httptest.NewServer(r)
	defer front.Close()
	fu, _ := url.Parse(front.URL)
	fport, _ := strconv.Atoi(fu.Port())
	r.Ports = append(r.Ports, fport)
	inner := front.URL + "/?url=" + url.QueryEscape(feed.URL+"/feed.xml")
	code, _, _ := relayStatus(t, front.URL+"/?url="+url.QueryEscape(inner),
		map[string]string{"Origin": "https://web.spokenmargins.test"})
	if code == 200 || hits.Load() != 0 {
		t.Fatalf("nested relay fetched the feed: %d, %d upstream hits", code, hits.Load())
	}
}

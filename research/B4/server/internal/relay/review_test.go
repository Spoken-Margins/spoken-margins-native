package relay_test

// Tests for the security review on #2986 (#2988), and the siblings of each
// finding.

import (
	"context"
	"net/http"
	"net/netip"
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

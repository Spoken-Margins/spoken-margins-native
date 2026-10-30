package relay_test

// Tests for the security review on #2986 (#2988), and the siblings of each
// finding.

import (
	"context"
	"net/http"
	"testing"
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

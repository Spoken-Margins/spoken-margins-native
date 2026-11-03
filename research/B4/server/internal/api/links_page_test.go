package api_test

import (
	"strings"
	"testing"
	"time"

	"spokenmargins.dev/bridge/internal/config"
	"spokenmargins.dev/bridge/internal/links"
)

// A friend opens an old link in a browser. Every way the page can fail answers a page in plain words, never
// the API's JSON (#3251). The apps keep the JSON on /preview and /packet.
func TestLinkPageAnswersWordsNotJSONWhenTheLinkCannotBeShown(t *testing.T) {
	s, path := enabledLinks(t)
	now := time.Date(2026, 10, 7, 0, 0, 0, 0, time.UTC)
	s.Now = func() time.Time { return now }
	h := s.Handler()
	expiring := createdLink(t, h)
	removed := createdLink(t, h)
	if w := linkRequest(h, "POST", "/l/"+removed+"/report", "application/x-www-form-urlencoded", []byte("category=copyright"), "203.0.113.7"); w.Code != 200 {
		t.Fatalf("report: %d %s", w.Code, w.Body)
	}
	unknown := strings.Repeat("0", 32)

	page := func(id string) (int, string, string) {
		w := linkRequest(h, "GET", "/l/"+id, "", nil, "203.0.113.7")
		return w.Code, w.Header().Get("Content-Type"), w.Body.String()
	}
	check := func(name string, status int, id string) string {
		code, contentType, body := page(id)
		if code != status {
			t.Errorf("%s: HTTP %d, want %d", name, code, status)
		}
		if !strings.HasPrefix(contentType, "text/html") {
			t.Errorf("%s: Content-Type %q, want text/html", name, contentType)
		}
		for _, raw := range []string{`{"error"`, "not_found", "expired_or_removed", "disabled", `"error":`} {
			if strings.Contains(body, raw) {
				t.Errorf("%s: the page shows %q: %s", name, raw, body)
			}
		}
		if !strings.Contains(body, "<h1>") || !strings.Contains(body, "Spoken Margins") {
			t.Errorf("%s: no plain page: %s", name, body)
		}
		return body
	}

	unknownBody := check("unknown", 404, unknown)
	removedBody := check("taken down", 410, removed)
	now = now.Add(links.Lifetime)
	expiredBody := check("expired", 410, expiring)
	// The words never name a takedown: an unknown, a removed and an expired link read the same.
	if unknownBody != removedBody || removedBody != expiredBody {
		t.Errorf("the three pages differ:\nunknown: %s\nremoved: %s\nexpired: %s", unknownBody, removedBody, expiredBody)
	}
	if !strings.Contains(unknownBody, "Ask your friend to share it again.") {
		t.Errorf("no next step: %s", unknownBody)
	}

	// The apps keep the JSON on the other routes.
	for _, suffix := range []string{"/preview", "/packet"} {
		w := linkRequest(h, "GET", "/l/"+expiring+suffix, "", nil, "203.0.113.7")
		if w.Code != 410 || !strings.Contains(w.Body.String(), `"error":"expired_or_removed"`) {
			t.Errorf("%s: HTTP %d %q, want the API's 410 JSON", suffix, w.Code, w.Body.String())
		}
		w = linkRequest(h, "GET", "/l/"+unknown+suffix, "", nil, "203.0.113.7")
		if w.Code != 404 || !strings.Contains(w.Body.String(), `"error":"not_found"`) {
			t.Errorf("%s unknown: HTTP %d %q, want the API's 404 JSON", suffix, w.Code, w.Body.String())
		}
	}

	// Service off: a page, with 503.
	if _, err := config.Set(path, config.ServiceLinks, false); err != nil {
		t.Fatal(err)
	}
	check("service off", 503, expiring)
}

func TestLinkPageUnavailableKeepsTheSecurityHeaders(t *testing.T) {
	s, _ := enabledLinks(t)
	h := s.Handler()
	w := linkRequest(h, "GET", "/l/"+strings.Repeat("0", 32), "", nil, "203.0.113.7")
	for header, want := range map[string]string{"Cache-Control": "no-store", "Referrer-Policy": "no-referrer", "X-Robots-Tag": "noindex, nofollow"} {
		if got := w.Header().Get(header); got != want {
			t.Errorf("%s = %q, want %q", header, got, want)
		}
	}
	if !strings.Contains(w.Header().Get("Content-Security-Policy"), "default-src 'none'") {
		t.Errorf("no CSP: %v", w.Header())
	}
}

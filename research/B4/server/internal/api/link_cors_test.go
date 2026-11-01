package api_test

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"spokenmargins.dev/bridge/internal/api"
	"spokenmargins.dev/bridge/internal/config"
	"spokenmargins.dev/bridge/internal/links"
)

const webApp = "https://web.example.com"

// One request with optional Origin and preflight headers, from a fixed client.
func corsRequest(h http.Handler, method, path, origin string, hdr map[string]string, body []byte, contentType string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, bytes.NewReader(body))
	r.RemoteAddr = "203.0.113.9:12345"
	if origin != "" {
		r.Header.Set("Origin", origin)
	}
	if contentType != "" {
		r.Header.Set("Content-Type", contentType)
	}
	for k, v := range hdr {
		r.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

// No answer from this server, on any route, ever allows credentials.
func noCredentials(t *testing.T, label string, w *httptest.ResponseRecorder) {
	t.Helper()
	if v := w.Header().Values("Access-Control-Allow-Credentials"); len(v) != 0 {
		t.Errorf("%s: Access-Control-Allow-Credentials %q", label, v)
	}
}

// No Access-Control-* header at all.
func noCORS(t *testing.T, label string, w *httptest.ResponseRecorder) {
	t.Helper()
	for k := range w.Header() {
		if strings.HasPrefix(k, "Access-Control-") {
			t.Errorf("%s: unexpected %s: %q", label, k, w.Header().Get(k))
		}
	}
}

func varyHasOrigin(w *httptest.ResponseRecorder) bool {
	for _, v := range w.Header().Values("Vary") {
		for _, f := range strings.Split(v, ",") {
			if strings.EqualFold(strings.TrimSpace(f), "Origin") {
				return true
			}
		}
	}
	return false
}

func corsLinks(t *testing.T, origins ...string) (*api.Server, string, http.Handler, string) {
	t.Helper()
	s, path := enabledLinks(t)
	s.LinkOrigins = origins
	now := time.Date(2026, 10, 30, 0, 0, 0, 0, time.UTC)
	s.Now = func() time.Time { return now }
	h := s.Handler()
	return s, path, h, createdLink(t, h)
}

// A listed origin reads the sealed packet and preview, byte for byte.
func TestLinkCORSListedOriginReadsSealedParts(t *testing.T) {
	_, _, h, id := corsLinks(t, webApp, "http://localhost:5173")
	for _, origin := range []string{webApp, "http://localhost:5173"} {
		for suffix, want := range map[string][]byte{"/packet": linkPacket, "/preview": linkPreview} {
			w := corsRequest(h, "GET", "/l/"+id+suffix, origin, nil, nil, "")
			label := origin + " " + suffix
			if w.Code != 200 || !bytes.Equal(w.Body.Bytes(), want) {
				t.Fatalf("%s: %d", label, w.Code)
			}
			if got := w.Header().Get("Access-Control-Allow-Origin"); got != origin {
				t.Errorf("%s: Access-Control-Allow-Origin %q", label, got)
			}
			if !varyHasOrigin(w) {
				t.Errorf("%s: no Vary: Origin", label)
			}
			if w.Header().Get("Cache-Control") != "no-store" || w.Header().Get("Referrer-Policy") != "no-referrer" {
				t.Errorf("%s: link headers lost", label)
			}
			noCredentials(t, label, w)
		}
	}
}

// The errors the web app reads (expired, unknown, switched off) carry the
// header too, or the browser would show it a network failure instead.
func TestLinkCORSErrorsAreReadable(t *testing.T) {
	s, path, h, id := corsLinks(t, webApp)
	for _, suffix := range []string{"/packet", "/preview"} {
		w := corsRequest(h, "GET", "/l/00000000000000000000000000000000"+suffix, webApp, nil, nil, "")
		if w.Code != 404 || w.Header().Get("Access-Control-Allow-Origin") != webApp {
			t.Errorf("unknown %s: %d %q", suffix, w.Code, w.Header().Get("Access-Control-Allow-Origin"))
		}
	}
	later := time.Date(2026, 10, 30, 0, 0, 0, 0, time.UTC).Add(links.Lifetime)
	s.Now = func() time.Time { return later }
	for _, suffix := range []string{"/packet", "/preview"} {
		w := corsRequest(h, "GET", "/l/"+id+suffix, webApp, nil, nil, "")
		if w.Code != 410 || w.Header().Get("Access-Control-Allow-Origin") != webApp {
			t.Errorf("expired %s: %d %q", suffix, w.Code, w.Header().Get("Access-Control-Allow-Origin"))
		}
	}
	if _, err := config.Set(path, config.ServiceLinks, false); err != nil {
		t.Fatal(err)
	}
	for _, suffix := range []string{"/packet", "/preview"} {
		w := corsRequest(h, "GET", "/l/"+id+suffix, webApp, nil, nil, "")
		if w.Code != 503 || w.Header().Get("Access-Control-Allow-Origin") != webApp {
			t.Errorf("off %s: %d %q", suffix, w.Code, w.Header().Get("Access-Control-Allow-Origin"))
		}
		noCredentials(t, "off "+suffix, w)
	}
}

// An unlisted origin, a missing Origin and every lookalike of the listed one
// get the same answer as before this change: the body, and no CORS headers.
// The answer still says it varies by Origin, so no cache mixes them up.
func TestLinkCORSUnlistedAndLookalikeOriginsGetNoHeaders(t *testing.T) {
	_, _, h, id := corsLinks(t, webApp)
	origins := []string{
		"",                                // no Origin: curl, the phone, a same-origin GET
		"https://other.example.com",       // unlisted
		"null",                            // sandboxed frame, file://, data:
		"HTTPS://web.example.com",         // case
		"https://WEB.example.com",         // case
		"https://Web.Example.Com",         // case
		"https://web.example.com/",        // trailing slash
		"https://web.example.com:443",     // explicit default port
		"https://web.example.com:8443",    // extra port
		"http://web.example.com",          // scheme
		"https://web.example.com.",        // trailing dot
		"https://web.example.com.evil.io", // suffix
		"https://evilweb.example.com",     // prefix
		"https://sub.web.example.com",     // subdomain
		" https://web.example.com",        // padding
		"https://web.example.com, https://other.example.com",
		"*",
	}
	for _, origin := range origins {
		for suffix, want := range map[string][]byte{"/packet": linkPacket, "/preview": linkPreview} {
			w := corsRequest(h, "GET", "/l/"+id+suffix, origin, nil, nil, "")
			label := "Origin " + origin + " " + suffix
			if w.Code != 200 || !bytes.Equal(w.Body.Bytes(), want) {
				t.Fatalf("%s: %d", label, w.Code)
			}
			noCORS(t, label, w)
			if !varyHasOrigin(w) {
				t.Errorf("%s: no Vary: Origin", label)
			}
		}
	}
}

// A preflight is answered for a listed origin asking for GET with no extra
// headers, and refused, with no CORS headers, for anything else.
func TestLinkCORSPreflight(t *testing.T) {
	_, _, h, id := corsLinks(t, webApp)
	for _, suffix := range []string{"/packet", "/preview"} {
		path := "/l/" + id + suffix
		w := corsRequest(h, "OPTIONS", path, webApp, map[string]string{"Access-Control-Request-Method": "GET"}, nil, "")
		if w.Code != 204 || w.Body.Len() != 0 {
			t.Fatalf("preflight %s: %d %s", suffix, w.Code, w.Body)
		}
		if w.Header().Get("Access-Control-Allow-Origin") != webApp || w.Header().Get("Access-Control-Allow-Methods") != "GET" || w.Header().Get("Access-Control-Max-Age") == "" {
			t.Errorf("preflight %s headers: %v", suffix, w.Header())
		}
		if w.Header().Get("Access-Control-Allow-Headers") != "" {
			t.Errorf("preflight %s allows request headers", suffix)
		}
		if !varyHasOrigin(w) {
			t.Errorf("preflight %s: no Vary: Origin", suffix)
		}
		noCredentials(t, "preflight "+suffix, w)

		refused := []struct {
			label, origin string
			hdr           map[string]string
		}{
			{"unlisted", "https://other.example.com", map[string]string{"Access-Control-Request-Method": "GET"}},
			{"no Origin", "", map[string]string{"Access-Control-Request-Method": "GET"}},
			{"null", "null", map[string]string{"Access-Control-Request-Method": "GET"}},
			{"case", "HTTPS://WEB.EXAMPLE.COM", map[string]string{"Access-Control-Request-Method": "GET"}},
			{"trailing slash", "https://web.example.com/", map[string]string{"Access-Control-Request-Method": "GET"}},
			{"extra port", "https://web.example.com:8443", map[string]string{"Access-Control-Request-Method": "GET"}},
			{"POST", webApp, map[string]string{"Access-Control-Request-Method": "POST"}},
			{"DELETE", webApp, map[string]string{"Access-Control-Request-Method": "DELETE"}},
			{"no method", webApp, nil},
			{"extra header", webApp, map[string]string{"Access-Control-Request-Method": "GET", "Access-Control-Request-Headers": "authorization"}},
		}
		for _, c := range refused {
			w := corsRequest(h, "OPTIONS", path, c.origin, c.hdr, nil, "")
			label := "preflight " + suffix + " " + c.label
			if w.Code != 403 {
				t.Errorf("%s: %d", label, w.Code)
			}
			noCORS(t, label, w)
		}
	}
}

// Uploads, reports, the share page and its scripts never answer CORS, even
// to a listed origin, and their preflights stay unrouted.
func TestLinkCORSOtherRoutesRefuse(t *testing.T) {
	_, _, h, id := corsLinks(t, webApp)
	data, ct := multipartLink(t, [][2][]byte{{[]byte("packet"), linkPacket}, {[]byte("preview"), linkPreview}})
	w := corsRequest(h, "POST", "/api/v1/links", webApp, nil, data, ct)
	if w.Code != 201 {
		t.Fatalf("upload: %d %s", w.Code, w.Body)
	}
	noCORS(t, "upload", w)
	// A report takes its link down, so it files against a second link.
	reported := createdLink(t, h)
	w = corsRequest(h, "POST", "/l/"+reported+"/report", webApp, nil, []byte("category=copyright"), "application/x-www-form-urlencoded")
	if w.Code != 200 {
		t.Fatalf("report: %d %s", w.Code, w.Body)
	}
	noCORS(t, "report", w)
	for _, path := range []string{"/l/" + id, "/l/share-link-page.mjs", "/l/share-link-open.mjs", "/api/v1/health", "/api/v1/config.json"} {
		w := corsRequest(h, "GET", path, webApp, nil, nil, "")
		if w.Code != 200 {
			t.Fatalf("GET %s: %d", path, w.Code)
		}
		noCORS(t, "GET "+path, w)
	}
	for _, path := range []string{"/api/v1/links", "/l/" + id + "/report", "/l/" + id, "/api/v1/tokens"} {
		for _, method := range []string{"POST", "GET"} {
			w := corsRequest(h, "OPTIONS", path, webApp, map[string]string{"Access-Control-Request-Method": method}, nil, "")
			if w.Code != 405 {
				t.Errorf("preflight %s %s: %d, want 405", method, path, w.Code)
			}
			noCORS(t, "preflight "+method+" "+path, w)
		}
	}
}

// With no origins listed (the default), no route sends a CORS header or a
// new Vary, and OPTIONS is still unrouted.
func TestLinkCORSOffByDefault(t *testing.T) {
	_, _, h, id := corsLinks(t)
	for _, path := range []string{"/l/" + id + "/packet", "/l/" + id + "/preview", "/l/" + id} {
		for _, origin := range []string{"", webApp, "null"} {
			w := corsRequest(h, "GET", path, origin, nil, nil, "")
			if w.Code != 200 {
				t.Fatalf("GET %s: %d", path, w.Code)
			}
			noCORS(t, "off GET "+path, w)
			if len(w.Header().Values("Vary")) != 0 {
				t.Errorf("off GET %s: Vary %q", path, w.Header().Values("Vary"))
			}
		}
		w := corsRequest(h, "OPTIONS", path, webApp, map[string]string{"Access-Control-Request-Method": "GET"}, nil, "")
		if w.Code != 405 {
			t.Errorf("off OPTIONS %s: %d, want 405", path, w.Code)
		}
		noCORS(t, "off OPTIONS "+path, w)
	}
}

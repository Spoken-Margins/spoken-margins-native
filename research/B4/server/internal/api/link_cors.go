package api

import (
	"net/http"

	"spokenmargins.dev/bridge/internal/weborigin"
)

// CORS for the web app (#3013). A web app on another origin opens a
// /l/<id>#<key> link by fetching the sealed packet and the sealed preview;
// without these headers the browser hides both responses from it.
//
// Only those two GET routes answer CORS, and only to an origin on
// LinkOrigins, matched exactly. Both bodies are sealed, and anyone holding
// the id can already fetch them outside a browser, so CORS here only decides
// which web apps' scripts may read them. Credentials are never allowed, so a
// browser never sends cookies with these requests and the server reads none.
// An Origin that isn't listed is answered as before, with no CORS headers:
// the share page's own fetch keeps working whatever its host is called.
//
// Uploads, reports and the share page itself never answer CORS. With
// LinkOrigins empty, nothing on any route changes.

// linkCORSMaxAge is how long a browser may reuse a preflight answer, in
// seconds. Ten minutes; Chrome caps it at two hours anyway.
const linkCORSMaxAge = "600"

// linkCORS wraps a sealed GET route. The headers are set before the route
// runs, so its errors (404, 410 expired, 503 off) are readable too, and the
// web app can tell an expired link from a network failure.
func (s *Server) linkCORS(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if len(s.LinkOrigins) > 0 {
			h := w.Header()
			// The answer depends on Origin whether or not this one is
			// listed, so no cache may hand one origin's answer to another.
			h.Add("Vary", "Origin")
			if origin := r.Header.Get("Origin"); weborigin.Allowed(s.LinkOrigins, origin) {
				h.Set("Access-Control-Allow-Origin", origin)
			}
		}
		next(w, r)
	}
}

// linkPreflight answers OPTIONS on a sealed GET route. The web app's fetch
// is a simple GET and needs no preflight, but a browser may still send one
// (an extension adding a header, a future fetch option), and it should get a
// plain answer rather than a 405. It allows GET with no extra request
// headers, for a listed origin only; anything else is refused with no CORS
// headers, so the browser blocks the request that would have followed.
func (s *Server) linkPreflight(w http.ResponseWriter, r *http.Request) {
	h := w.Header()
	h.Add("Vary", "Origin")
	h.Add("Vary", "Access-Control-Request-Method")
	h.Add("Vary", "Access-Control-Request-Headers")
	h.Set("Cache-Control", "no-store")
	origin := r.Header.Get("Origin")
	if !weborigin.Allowed(s.LinkOrigins, origin) ||
		r.Header.Get("Access-Control-Request-Method") != http.MethodGet ||
		r.Header.Get("Access-Control-Request-Headers") != "" {
		fail(w, http.StatusForbidden, "origin_refused")
		return
	}
	h.Set("Access-Control-Allow-Origin", origin)
	h.Set("Access-Control-Allow-Methods", http.MethodGet)
	h.Set("Access-Control-Max-Age", linkCORSMaxAge)
	w.WriteHeader(http.StatusNoContent)
}

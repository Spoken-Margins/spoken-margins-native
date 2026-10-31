package api

import (
	"net/http"

	"spokenmargins.dev/bridge/internal/config"
)

// PathRelay fetches one feed or page for the web app: GET ?url=…. The
// request log names this path only; the query, which holds the URL, is
// never written anywhere.
const PathRelay = "/api/v1/relay"

// relayOn follows linksOn: the owner's switch in config.json, and a relay
// configured with at least one web app origin on the command line.
func (s *Server) relayOn(w http.ResponseWriter) bool {
	doc, err := s.Config.Current()
	if err != nil || !doc.Enabled(config.ServiceRelay) || s.Relay == nil || len(s.Relay.Origins) == 0 {
		fail(w, http.StatusServiceUnavailable, "disabled")
		return false
	}
	return true
}

func (s *Server) relay(w http.ResponseWriter, r *http.Request) {
	// Before the switch is checked, so a listed web app can read "disabled"
	// as well as every later refusal; a browser hides an answer without it.
	if s.Relay != nil {
		s.Relay.CORS(w, r)
	}
	if !s.relayOn(w) {
		return
	}
	// A caller the relay refuses (no listed Origin) is answered before the
	// limit counts it, so a page on another site can't spend a visitor's
	// budget by embedding the relay.
	if !s.Relay.Admit(w, r) {
		return
	}
	// Per client per hour, keyed through the HMAC like linkWindow, so the
	// address itself is never held.
	if !s.relayWindow.hit(s.clientKey(r), s.Now(), s.RelayPerIPPerHour) {
		fail(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	s.Relay.ServeHTTP(w, r)
}

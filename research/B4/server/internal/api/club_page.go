package api

import (
	"bytes"
	"net/http"

	"spokenmargins.dev/bridge/internal/clubs"
	"spokenmargins.dev/bridge/internal/links"
)

// The page a club invite opens in a browser (#1799, docs/design/club-mailbox.md section 10, slice 4).
//
// It never looks the club up: every id of the right shape gets the same 200 shell, so the page cannot tell a
// stranger which clubs exist, ended or were taken down (the rule that gives every other club answer one 404).
// What differs is only what the whole server decides, the same for every id: an address that cannot be a
// club's reads 404, and the clubs switch being off reads 503. The key is in the address's # part and never
// reaches this handler; the page's script reads it in the browser.
func (s *Server) getClubPage(w http.ResponseWriter, r *http.Request) {
	clubPageHeaders(w)
	if !s.clubsUp() {
		s.clubUnavailablePage(w, http.StatusServiceUnavailable, clubs.UnavailablePaused)
		return
	}
	id := r.PathValue("id")
	if !clubs.ValidID(id) {
		s.clubUnavailablePage(w, http.StatusNotFound, clubs.UnavailableMalformed)
		return
	}
	var page bytes.Buffer
	installURL := ""
	// The browser is offered the app's install link unless it says it is an Android one, as on the unavailable
	// share page (#3799); the header is read for that answer and never kept.
	if links.OffersIPhoneInstall(r.UserAgent()) {
		installURL = s.LinkInstallURL
	}
	if err := clubs.Render(&page, id, installURL); err != nil {
		s.clubUnavailablePage(w, http.StatusNotFound, clubs.UnavailableMalformed)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write(page.Bytes())
}

func (s *Server) clubUnavailablePage(w http.ResponseWriter, status int, reason clubs.Unavailable) {
	var page bytes.Buffer
	if err := clubs.RenderUnavailable(&page, reason); err != nil {
		fail(w, http.StatusInternalServerError, "internal")
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	w.Write(page.Bytes())
}

// The page's one module, embedded in the binary. It is served while the clubs switch is on, like the page.
func (s *Server) getClubScript(w http.ResponseWriter, r *http.Request) {
	clubPageHeaders(w)
	if !s.clubsOn(w) {
		return
	}
	data, ok := clubs.PageScript("club-page.mjs")
	if !ok {
		fail(w, http.StatusNotFound, "not_found")
		return
	}
	w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
	w.Write(data)
}

// clubPageHeaders: the page runs only its own module and makes no request, so the policy lets it fetch nothing.
func clubPageHeaders(w http.ResponseWriter) {
	clubHeaders(w)
	w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; form-action 'none'; base-uri 'none'; frame-ancestors 'none'")
}

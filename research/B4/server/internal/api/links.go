package api

import (
	"bytes"
	"errors"
	"io"
	"mime"
	"mime/multipart"
	"net/http"
	"strings"
	"time"

	"spokenmargins.dev/bridge/internal/config"
	"spokenmargins.dev/bridge/internal/links"
)

const PathLinks = "/api/v1/links"
const routeLinks = "/l/*"

func (s *Server) linksOn(w http.ResponseWriter) bool {
	doc, err := s.Config.Current()
	if err != nil || !doc.Enabled(config.ServiceLinks) || s.Links == nil || !links.ValidInstallURL(s.LinkInstallURL) {
		fail(w, http.StatusServiceUnavailable, "disabled")
		return false
	}
	return true
}

// Upload is multipart/form-data with exactly two parts, preview and packet, in
// either order. Both are sealed on the phone (#805) and stored as they came: the
// server checks only their sealed header and size, never decodes them, and asks
// for no identity.
func (s *Server) uploadLink(w http.ResponseWriter, r *http.Request) {
	if !s.linksOn(w) {
		return
	}
	if !s.linkWindow.hit(s.clientKey(r), s.Now(), 30) {
		fail(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	// One buffered packet at a time leaves room under the service's 128 MB
	// limit for map uploads, runtime overhead and growing read buffers.
	select {
	case s.linkSlots <- struct{}{}:
		defer func() { <-s.linkSlots }()
	default:
		fail(w, http.StatusServiceUnavailable, "busy")
		return
	}
	// Bound multipart headers and framing too; ParseMultipartForm would spill
	// oversized uploads to disk before enforcing the individual part limits.
	r.Body = http.MaxBytesReader(w, r.Body, links.MaxPacketBytes+links.MaxPreviewBytes+(64<<10))
	media, params, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || media != "multipart/form-data" || params["boundary"] == "" {
		fail(w, http.StatusBadRequest, "bad_request")
		return
	}
	mr := multipart.NewReader(r.Body, params["boundary"])
	var packet, preview []byte
	seen := map[string]bool{}
	for {
		part, err := mr.NextPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			linkReadFailure(w, err)
			return
		}
		name := part.FormName()
		if seen[name] || (name != "preview" && name != "packet") {
			fail(w, http.StatusBadRequest, "bad_request")
			return
		}
		seen[name] = true
		limit := links.MaxPacketBytes
		if name == "preview" {
			limit = links.MaxPreviewBytes
		}
		data, err := io.ReadAll(io.LimitReader(part, int64(limit)+1))
		if err != nil {
			linkReadFailure(w, err)
			return
		}
		if len(data) > limit {
			fail(w, http.StatusRequestEntityTooLarge, "too_large")
			return
		}
		if name == "preview" {
			preview = data
		} else {
			packet = data
		}
	}
	if !seen["preview"] || !seen["packet"] || len(packet) == 0 {
		fail(w, http.StatusBadRequest, "bad_request")
		return
	}
	if !links.Sealed(preview, links.PartPreview) {
		fail(w, http.StatusBadRequest, "bad_preview")
		return
	}
	if !links.Sealed(packet, links.PartPacket) {
		fail(w, http.StatusBadRequest, "bad_packet")
		return
	}
	id, expires, err := s.Links.Put(packet, preview, s.Now())
	if err != nil {
		fail(w, http.StatusInternalServerError, "internal")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"id": id, "path": "/l/" + id, "expiresAt": expires})
}

func linkReadFailure(w http.ResponseWriter, err error) {
	var large *http.MaxBytesError
	if errors.As(err, &large) {
		fail(w, http.StatusRequestEntityTooLarge, "too_large")
	} else {
		fail(w, http.StatusBadRequest, "bad_request")
	}
}

func linkFailure(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, links.ErrNotFound):
		fail(w, http.StatusNotFound, "not_found")
	case errors.Is(err, links.ErrGone):
		fail(w, http.StatusGone, "expired_or_removed")
	default:
		fail(w, http.StatusInternalServerError, "internal")
	}
}

func linkHeaders(w http.ResponseWriter) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("X-Robots-Tag", "noindex, nofollow")
	// The page runs only its own two modules and fetches only its own sealed preview.
	w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; connect-src 'self'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
}

func (s *Server) getLink(w http.ResponseWriter, r *http.Request) {
	linkHeaders(w)
	if !s.linksOn(w) {
		return
	}
	id := r.PathValue("id")
	if err := s.Links.Live(id, s.Now()); err != nil {
		linkFailure(w, err)
		return
	}
	var page bytes.Buffer
	if err := links.Render(&page, id, s.LinkInstallURL); err != nil {
		linkFailure(w, err)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write(page.Bytes())
}

// The sealed preview, byte for byte. The landing page opens it in the browser.
func (s *Server) getLinkPreview(w http.ResponseWriter, r *http.Request) {
	linkHeaders(w)
	if !s.linksOn(w) {
		return
	}
	data, err := s.Links.Preview(r.PathValue("id"), s.Now())
	if err != nil {
		linkFailure(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Write(data)
}

// The landing page's two modules, embedded in the binary.
func (s *Server) getLinkScript(w http.ResponseWriter, r *http.Request) {
	linkHeaders(w)
	if !s.linksOn(w) {
		return
	}
	data, ok := links.PageScript(strings.TrimPrefix(r.URL.Path, "/l/"))
	if !ok {
		fail(w, http.StatusNotFound, "not_found")
		return
	}
	w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
	w.Write(data)
}

func (s *Server) getLinkPacket(w http.ResponseWriter, r *http.Request) {
	linkHeaders(w)
	if !s.linksOn(w) {
		return
	}
	f, err := s.Links.Packet(r.PathValue("id"), s.Now())
	if err != nil {
		linkFailure(w, err)
		return
	}
	defer f.Close()
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", `attachment; filename="shared.spokenmargins"`)
	http.ServeContent(w, r, "", time.Time{}, f)
}

// Reasons are a fixed vocabulary, so reports cannot put addresses, personal
// details or attacker-chosen HTML into the existing hourly abuse log.
func (s *Server) reportLink(w http.ResponseWriter, r *http.Request) {
	linkHeaders(w)
	if !s.linksOn(w) {
		return
	}
	if !s.linkReportWindow.hit(s.clientKey(r), s.Now(), 30) {
		fail(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	id := r.PathValue("id")
	if err := s.Links.Live(id, s.Now()); err != nil {
		linkFailure(w, err)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 1024)
	if err := r.ParseForm(); err != nil {
		fail(w, http.StatusBadRequest, "bad_request")
		return
	}
	// Read the body only: query parameters cannot select a report reason.
	reasons := r.PostForm["reason"]
	if len(reasons) != 1 {
		fail(w, http.StatusBadRequest, "bad_request")
		return
	}
	reason := reasons[0]
	switch reason {
	case "privacy", "copyright", "harmful", "spam", "other":
	default:
		fail(w, http.StatusBadRequest, "bad_reason")
		return
	}
	s.countLinkReport(linkReportKey{hour: s.Now().UTC().Format("2006-01-02T15"), id: id, reason: reason})
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	io.WriteString(w, `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Link reported</title><p>Thank you. This link has been reported for review.</p></html>`)
}

type linkReportKey struct{ hour, id, reason string }

func (s *Server) countLinkReport(k linkReportKey) {
	s.logMu.Lock()
	defer s.logMu.Unlock()
	if s.linkReports == nil {
		s.linkReports = map[linkReportKey]int{}
	}
	s.linkReports[k]++
}

// All paths below /l/, including malformed ids and reports, share one route.
func isLinkRoute(path string) bool { return strings.HasPrefix(path, "/l/") }

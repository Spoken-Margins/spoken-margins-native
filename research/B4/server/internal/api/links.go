package api

import (
	"bytes"
	"errors"
	"io"
	"mime"
	"net/http"
	"time"

	"spokenmargins.dev/bridge/internal/config"
	"spokenmargins.dev/bridge/internal/links"
)

// Share links (#486): an app uploads a packet and a small preview, and gets
// back an id. Anyone with /l/<id> sees a page with the Margins and a short
// excerpt of the source, can download the packet, and can report the link.
// Like map uploads, nothing here is attested (DESIGN.md §3): a link must not
// say which install made it.

// linkUploadOverhead is room for the multipart framing around the preview
// and the packet.
const linkUploadOverhead = 64 << 10

func (s *Server) linksOn() bool {
	doc, err := s.Config.Current()
	return err == nil && doc.Enabled(config.ServiceLinks) && s.LinkStore != nil
}

// createLink takes a multipart/form-data body with two parts, in this order:
// "preview" (the JSON preview, at most 16 KB) and "packet" (the packet, at
// most 20 MB). The preview comes first so a bad one is refused before any
// packet bytes are written. It answers 201 with the id and the page path.
func (s *Server) createLink(w http.ResponseWriter, r *http.Request) {
	if !s.linksOn() {
		fail(w, http.StatusServiceUnavailable, "disabled")
		return
	}
	client := s.networkKey(r)
	if !s.linkWindow.hit(client, s.Now(), s.LinkUploadsPerIPPerHour) {
		fail(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	// One upload at a time per client, so one slow sender can't hold every
	// slot and lock everyone else out.
	if !s.startLinkUpload(client) {
		fail(w, http.StatusTooManyRequests, "one_at_a_time")
		return
	}
	defer s.endLinkUpload(client)
	select {
	case s.linkSlots <- struct{}{}:
		defer func() { <-s.linkSlots }()
	default:
		fail(w, http.StatusServiceUnavailable, "busy")
		return
	}
	// A slow phone needs longer than the server-wide timeouts for 20 MB,
	// and the answer with the id must still reach it after the body has.
	rc := http.NewResponseController(w)
	rc.SetReadDeadline(time.Now().Add(linkUploadTime))
	rc.SetWriteDeadline(time.Now().Add(linkUploadTime + 30*time.Second))
	if mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type")); err != nil || mediaType != "multipart/form-data" {
		fail(w, http.StatusBadRequest, "bad_request")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, links.MaxPacketBytes+links.MaxPreviewBytes+linkUploadOverhead)
	mr, err := r.MultipartReader()
	if err != nil {
		fail(w, http.StatusBadRequest, "bad_request")
		return
	}

	part, err := mr.NextPart()
	if err != nil || part.FormName() != "preview" {
		fail(w, http.StatusBadRequest, "bad_request")
		return
	}
	raw, err := io.ReadAll(io.LimitReader(part, links.MaxPreviewBytes+1))
	if err != nil {
		fail(w, http.StatusBadRequest, "bad_request")
		return
	}
	if len(raw) > links.MaxPreviewBytes {
		fail(w, http.StatusRequestEntityTooLarge, "too_large")
		return
	}
	preview, err := links.ParsePreview(raw)
	if err != nil {
		fail(w, http.StatusBadRequest, "bad_preview")
		return
	}

	part, err = mr.NextPart()
	if err != nil || part.FormName() != "packet" {
		fail(w, http.StatusBadRequest, "bad_request")
		return
	}
	now := s.Now()
	id, err := s.LinkStore.Create(part, preview, now)
	var tooBig *http.MaxBytesError
	switch {
	case errors.Is(err, links.ErrTooLarge), errors.As(err, &tooBig):
		fail(w, http.StatusRequestEntityTooLarge, "too_large")
		return
	case errors.Is(err, links.ErrBadPacket):
		fail(w, http.StatusBadRequest, "bad_packet")
		return
	case errors.Is(err, links.ErrFull):
		fail(w, http.StatusServiceUnavailable, "busy")
		return
	case err != nil:
		fail(w, http.StatusInternalServerError, "internal")
		return
	}
	// Nothing may follow the packet.
	if _, err := mr.NextPart(); err != io.EOF {
		s.LinkStore.Takedown(id)
		fail(w, http.StatusBadRequest, "bad_request")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{
		"id":        id,
		"path":      pathLinkPrefix + id,
		"expiresAt": now.UTC().Add(links.Lifetime).Format(time.RFC3339),
	})
}

func (s *Server) startLinkUpload(client string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.linkUploads == nil {
		s.linkUploads = map[string]bool{}
	}
	if s.linkUploads[client] {
		return false
	}
	s.linkUploads[client] = true
	return true
}

func (s *Server) endLinkUpload(client string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.linkUploads, client)
}

// htmlHeaders keep the page private to whoever opens it: no caching (so a
// takedown is immediate), no indexing, and no Referer, so the source site a
// reader clicks through to never learns the link's id.
func htmlHeaders(w http.ResponseWriter) {
	h := w.Header()
	h.Set("Content-Type", "text/html; charset=utf-8")
	h.Set("Cache-Control", "no-store")
	h.Set("Content-Security-Policy", links.PageCSP)
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("X-Robots-Tag", "noindex")
}

func (s *Server) notice(w http.ResponseWriter, status int, title, message string) {
	htmlHeaders(w)
	if status == http.StatusServiceUnavailable {
		w.Header().Set("Retry-After", "3600")
	}
	var b bytes.Buffer
	links.RenderNotice(&b, links.Notice{Title: title, Message: message, InstallURL: s.InstallURL})
	w.WriteHeader(status)
	w.Write(b.Bytes())
}

// linkFailure answers a page, packet or report request for a link that
// can't be shown. Expired and unknown read alike to a visitor.
func (s *Server) linkFailure(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, links.ErrExpired):
		s.notice(w, http.StatusGone, "This link has expired", "Shared Margins links work for 30 days.")
	case errors.Is(err, links.ErrNotFound):
		s.notice(w, http.StatusNotFound, "This link isn't available", "It may have expired or been removed.")
	default:
		s.notice(w, http.StatusInternalServerError, "Something went wrong", "Please try again later.")
	}
}

func (s *Server) linksOff(w http.ResponseWriter) {
	s.notice(w, http.StatusServiceUnavailable, "Shared links are switched off", "Please try again later.")
}

func (s *Server) linkPage(w http.ResponseWriter, r *http.Request) {
	if !s.linksOn() {
		s.linksOff(w)
		return
	}
	id := r.PathValue("id")
	l, err := s.LinkStore.Get(id, s.Now())
	if err != nil {
		s.linkFailure(w, err)
		return
	}
	var b bytes.Buffer
	if err := links.RenderPage(&b, links.Page{ID: id, Link: l, InstallURL: s.InstallURL}); err != nil {
		s.linkFailure(w, err)
		return
	}
	htmlHeaders(w)
	w.Write(b.Bytes())
}

// linkPacket returns the stored packet bytes unchanged, for the app to import.
func (s *Server) linkPacket(w http.ResponseWriter, r *http.Request) {
	if !s.linksOn() {
		fail(w, http.StatusServiceUnavailable, "disabled")
		return
	}
	f, err := s.LinkStore.OpenPacket(r.PathValue("id"), s.Now())
	switch {
	case errors.Is(err, links.ErrExpired):
		fail(w, http.StatusGone, "expired")
		return
	case errors.Is(err, links.ErrNotFound):
		fail(w, http.StatusNotFound, "not_found")
		return
	case err != nil:
		fail(w, http.StatusInternalServerError, "internal")
		return
	}
	defer f.Close()
	// Up to 20 MB to a recipient on a slow connection.
	http.NewResponseController(w).SetWriteDeadline(time.Now().Add(linkDownloadTime))
	h := w.Header()
	h.Set("Content-Type", "application/vnd.spokenmargins.package+zip")
	h.Set("Content-Disposition", `attachment; filename="Shared Margins.spokenmargins"`)
	h.Set("Cache-Control", "no-store")
	h.Set("X-Content-Type-Options", "nosniff")
	http.ServeContent(w, r, "", time.Time{}, f)
}

// reportLink records a report from the page's form in the abuse log (hour,
// link id, reason, count; never who sent it) for the owner to review.
func (s *Server) reportLink(w http.ResponseWriter, r *http.Request) {
	if !s.linksOn() {
		s.linksOff(w)
		return
	}
	now := s.Now()
	if !s.reportWindow.hit(s.networkKey(r), now, s.LinkReportsPerIPPerHour) {
		s.notice(w, http.StatusTooManyRequests, "Too many reports", "Please try again in an hour.")
		return
	}
	id := r.PathValue("id")
	if _, err := s.LinkStore.Get(id, now); err != nil {
		s.linkFailure(w, err)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 1<<10)
	reason := links.ReportReason(r.PostFormValue("reason"))
	s.countAbuse(abuseKey{hour: now.UTC().Format("2006-01-02T15"), link: id, reason: "report:" + reason})
	s.notice(w, http.StatusOK, "Thank you", "Your report was sent to the people who run Spoken Margins.")
}

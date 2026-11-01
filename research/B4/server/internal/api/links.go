package api

import (
	"bytes"
	"errors"
	"html"
	"io"
	"log"
	"mime"
	"mime/multipart"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"spokenmargins.dev/bridge/internal/config"
	"spokenmargins.dev/bridge/internal/links"
	"spokenmargins.dev/bridge/internal/reportrules"
	"spokenmargins.dev/bridge/internal/reports"
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

// Report this link (#2239). Every report takes the link down at once and blind: nobody reads what it
// held. The category is required from the first report; the written reason is owed from a reporter's
// second report within 7 days, in every category, and is collected on a second page so it never holds
// up the takedown. Only an abuse-material report may send the full link, key included: it is held for a
// year unread (links.Store.Hold, #2235) before the link comes down. For every other category a "link"
// field is dropped unread, so the key is never stored.
const (
	// Room for a 2048-byte link and a 6000-byte reason, each percent-encoded.
	maxReportForm = 32 << 10
	maxReportLink = 2048
	// The reporter's handle is kept for the 7-day reason window and the record for the 90-day strike
	// window, no longer (reports.Store.Sweep).
	reportHandleKeep = 7 * 24 * time.Hour
	reportRecordKeep = 90 * 24 * time.Hour
)

func (s *Server) reportConfig() reportrules.Config {
	if s.ReportRules.ReasonWindow == 0 {
		return reportrules.DefaultConfig()
	}
	return s.ReportRules
}

func (s *Server) reportLink(w http.ResponseWriter, r *http.Request) {
	linkHeaders(w)
	if !s.linksOn(w) {
		return
	}
	if s.Reports == nil {
		fail(w, http.StatusServiceUnavailable, "disabled")
		return
	}
	if !s.linkReportWindow.hit(s.clientKey(r), s.Now(), 30) {
		fail(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	id := r.PathValue("id")
	r.Body = http.MaxBytesReader(w, r.Body, maxReportForm)
	if err := r.ParseForm(); err != nil {
		fail(w, http.StatusBadRequest, "bad_request")
		return
	}
	// Read the body only: query parameters cannot choose a category or a reason.
	categories, reasons, fulls := r.PostForm["category"], r.PostForm["reason"], r.PostForm["link"]
	if len(categories) != 1 || len(reasons) > 1 || len(fulls) > 1 {
		fail(w, http.StatusBadRequest, "bad_request")
		return
	}
	reason := ""
	if len(reasons) == 1 {
		reason = strings.TrimSpace(reasons[0])
		if len(reason) > reports.MaxReasonBytes || !utf8.ValidString(reason) {
			fail(w, http.StatusBadRequest, "bad_reason")
			return
		}
	}
	now := s.Now()
	cfg := s.reportConfig()
	handle := s.Reports.Handle("net", s.clientNetOf(r))
	prior := s.Reports.Note(handle, now, cfg.ReasonWindow)
	d := cfg.Intake(reportrules.Submission{Category: categories[0], Reason: reason, Channel: reportrules.ChannelForm}, prior, now)
	if d.Err != nil {
		fail(w, http.StatusBadRequest, "bad_category")
		return
	}
	ref, err := reports.NewRef()
	if err != nil {
		fail(w, http.StatusInternalServerError, "internal")
		return
	}
	if d.SendFullLink {
		// Hold before takedown: a plain takedown deletes the ciphertext the year-long hold has to keep.
		// The link is used only if it names this link id; a missing or wrong one never stops the takedown.
		var full []byte
		if len(fulls) == 1 && len(fulls[0]) <= maxReportLink && strings.Contains(fulls[0], "/l/"+id) {
			full = []byte(strings.TrimSpace(fulls[0]))
		}
		perClient := s.HoldsPerClientPerDay
		if perClient <= 0 {
			perClient = 5
		}
		// Only a link that exists, and is not already held, can use up a client's allowance or raise a cap
		// alert: a made-up id must not forge an alert for the owner, and a re-report of a held link begins no
		// new hold (its link is added to the held ones, up to the per-item cap).
		if err := s.Links.Live(id, now); errors.Is(err, links.ErrNotFound) {
			linkFailure(w, err)
			return
		}
		var holdErr error
		if !s.Links.IsHeld(id) {
			if _, ok := s.holdQuota.reserve(s.clientKey(r), 1, perClient, now); !ok {
				holdErr = links.ErrHoldCap
				if err := s.Links.NoteHoldRefused(id, "holds today from one client network at the cap of "+strconv.Itoa(perClient), now); err != nil {
					log.Print("reports: cap line could not be written")
				}
			}
		}
		if holdErr == nil {
			holdErr = s.Links.Hold(id, "form-"+ref, full, now)
		}
		if holdErr != nil {
			if errors.Is(holdErr, links.ErrNotFound) {
				linkFailure(w, holdErr)
				return
			}
			if errors.Is(holdErr, links.ErrHoldCap) {
				// Not a plain takedown, which would delete the ciphertext a real report needs. The link goes
				// dark and keeps its content until its own 30 days are up. The owner is alerted and decides
				// (docs/legal/cybertipline-runbook.md, "The hold cap"). The reporter did nothing wrong, so
				// they see the normal page.
				log.Print("reports: HOLD CAP REACHED, link disabled and its content kept 30 days; the owner must hold it by hand (see the access log)")
				// The key goes beside the ciphertext, or the owner's hold by hand could not open it.
				if len(full) > 0 {
					if err := s.Links.ParkLink(id, full); err != nil {
						log.Print("reports: reported link could not be parked")
					}
				}
				if err := s.Links.Disable(id, now); err != nil {
					log.Print("reports: link could not be disabled")
					fail(w, http.StatusInternalServerError, "internal")
					return
				}
			} else if !errors.Is(s.Links.Live(id, now), links.ErrGone) {
				// The hold did its work if the link is already down (only its log line failed). Otherwise the
				// link goes dark now and keeps its content, so a retry can still hold it; the reporter is told
				// to try again and the owner's runbook command holds it by hand.
				log.Print("reports: hold failed, link disabled without a hold")
				if s.Links.Disable(id, now) != nil {
					log.Print("reports: link could not be disabled")
				}
				fail(w, http.StatusInternalServerError, "internal")
				return
			} else {
				log.Print("reports: hold finished with an error")
			}
		}
	} else {
		if err := s.Links.Live(id, now); err != nil {
			linkFailure(w, err)
			return
		}
		if err := s.Links.Takedown(id); err != nil {
			linkFailure(w, err)
			return
		}
	}
	s.countLinkReport(linkReportKey{hour: now.UTC().Format("2006-01-02T15"), id: id, reason: string(d.Category)})
	// The link is already down. A record that fails to save must not turn that into an error page.
	filed := s.Reports.Add(reports.Record{Ref: ref, LinkID: id, Category: d.Category, At: now, Reason: reason}) == nil
	if !filed {
		log.Print("reports: record not saved")
	}
	writeReportPage(w, id, ref, filed, d.ReasonOutstanding && filed)
}

// reportReason is the second page of the form: it adds the written reason to a report already filed.
func (s *Server) reportReason(w http.ResponseWriter, r *http.Request) {
	linkHeaders(w)
	if !s.linksOn(w) {
		return
	}
	if s.Reports == nil {
		fail(w, http.StatusServiceUnavailable, "disabled")
		return
	}
	if !s.linkReportWindow.hit(s.clientKey(r), s.Now(), 30) {
		fail(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	id := r.PathValue("id")
	r.Body = http.MaxBytesReader(w, r.Body, maxReportForm)
	if err := r.ParseForm(); err != nil {
		fail(w, http.StatusBadRequest, "bad_request")
		return
	}
	refs, reasons := r.PostForm["ref"], r.PostForm["reason"]
	if len(refs) != 1 || len(reasons) != 1 {
		fail(w, http.StatusBadRequest, "bad_request")
		return
	}
	switch err := s.Reports.AddReason(refs[0], id, reasons[0]); {
	case err == nil, errors.Is(err, reports.ErrReasonGiven):
	case errors.Is(err, reports.ErrReasonMissing), errors.Is(err, reports.ErrReasonTooLong):
		fail(w, http.StatusBadRequest, "bad_reason")
		return
	case errors.Is(err, reports.ErrNotFound):
		fail(w, http.StatusNotFound, "not_found")
		return
	default:
		fail(w, http.StatusInternalServerError, "internal")
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	io.WriteString(w, `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Report received</title><p>Thank you. Your reason has been added to the report.</p>`)
	io.WriteString(w, policyFooter()+`</html>`)
}

// writeReportPage is the acknowledgement. ref is letters and digits only, so it needs no escaping.
func writeReportPage(w http.ResponseWriter, id, ref string, filed, askReason bool) {
	id, ref = html.EscapeString(id), html.EscapeString(ref)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	var b strings.Builder
	b.WriteString(`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Link reported</title><p>Thank you. This link has been taken down.</p>`)
	if filed {
		b.WriteString(`<p>Your reference number is <strong>` + ref + `</strong>.</p>`)
	}
	if askReason {
		b.WriteString(`<form method="post" action="/l/` + id + `/report/reason"><input type="hidden" name="ref" value="` + ref + `"><p><label for="reason">Please tell us briefly why you are reporting this link. A few words are enough.</label></p><p><textarea id="reason" name="reason" rows="4" cols="40" maxlength="2000" required></textarea></p><button type="submit">Send</button></form>`)
	}
	b.WriteString(policyFooter() + `</html>`)
	io.WriteString(w, b.String())
}

// policyFooter links the published policies from the report pages (#2238). The titles and paths are
// constants in the links package, so they need no escaping.
func policyFooter() string {
	var b strings.Builder
	b.WriteString(`<footer><p>`)
	for i, l := range links.PolicyLinks {
		if i > 0 {
			b.WriteString(` · `)
		}
		b.WriteString(`<a href="` + l.Path + `">` + l.Title + `</a>`)
	}
	b.WriteString(`</p></footer>`)
	return b.String()
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

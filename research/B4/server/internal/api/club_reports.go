package api

import (
	"errors"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"spokenmargins.dev/bridge/internal/clubs"
	"spokenmargins.dev/bridge/internal/reportrules"
	"spokenmargins.dev/bridge/internal/reports"
)

// Report a club or one post in it (#1799, docs/design/club-mailbox.md section 7, Apple agreement 10(v)).
// It follows the share-link report (links.go, #2239) with the differences the design lists:
//
//   - The route is POST /api/v1/clubs/{id}/report, a form with category, an optional reason, an optional
//     link (abuse material only) and an optional post number. The answer is JSON, because the report
//     comes from the app. A second route, .../report/reason, adds the written reason a second report owes.
//   - A report that names a post must carry the club's read proof as a bearer value, so someone who only
//     saw a club id in a link preview cannot silence posts. It disables that one post. A whole-club
//     report needs only the id and disables that club, as a link report needs only the link id.
//   - An abuse-material report holds the club's ciphertext for a year with the full invite link the form
//     sent, key included, and ends the club (clubs.Store.Hold, before the takedown). Nothing else sends
//     the key, and a "link" field in any other category is dropped unread.
//   - The abuse log counts a club report under the one key clubAbuseKey, never the club id.
//   - There is no sender behind a club post, so no strike is counted.
//
// A wrong or missing proof, an unknown club and a club that has ended all answer the same 404 to a
// reporter without the club's proof.
const (
	maxClubReportForm = 32 << 10
	// clubAbuseKey is the id column of the abuse log's report lines for clubs. It names no club.
	clubAbuseKey = "club"
	// clubReportsPerHour is the per-network limit on report requests, as link reports have.
	clubReportsPerHour = 30
)

func (s *Server) reportClub(w http.ResponseWriter, r *http.Request) {
	clubHeaders(w)
	if !s.clubsOn(w) {
		return
	}
	if s.Reports == nil {
		fail(w, http.StatusServiceUnavailable, "disabled")
		return
	}
	if !s.clubReportWindow.hit(s.clientKey(r), s.Now(), clubReportsPerHour) {
		fail(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	id := r.PathValue("id")
	r.Body = http.MaxBytesReader(w, r.Body, maxClubReportForm)
	if err := r.ParseForm(); err != nil {
		fail(w, http.StatusBadRequest, "bad_request")
		return
	}
	// Read the body only: query parameters cannot choose a category, a reason or a post.
	categories, reasons, fulls, posts := r.PostForm["category"], r.PostForm["reason"], r.PostForm["link"], r.PostForm["post"]
	if len(categories) != 1 || len(reasons) > 1 || len(fulls) > 1 || len(posts) > 1 {
		fail(w, http.StatusBadRequest, "bad_request")
		return
	}
	post := 0
	if len(posts) == 1 {
		n, err := strconv.Atoi(posts[0])
		if err != nil || n < 1 || strconv.Itoa(n) != posts[0] {
			fail(w, http.StatusBadRequest, "bad_request")
			return
		}
		post = n
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
	proof := clubProof(r)
	if d.SendFullLink {
		if !s.holdReportedClub(w, r, id, post, proof, ref, fulls, now) {
			return
		}
	} else if post > 0 {
		if err := s.Clubs.DisablePost(id, proof, post, now); err != nil {
			clubFailure(w, err)
			return
		}
	} else {
		if err := s.Clubs.Reportable(id, now, false); err != nil {
			clubFailure(w, err)
			return
		}
		if err := s.Clubs.Disable(id, now); err != nil {
			log.Print("reports: club could not be disabled")
			fail(w, http.StatusInternalServerError, "internal")
			return
		}
	}
	s.countLinkReport(linkReportKey{hour: now.UTC().Format("2006-01-02T15"), id: clubAbuseKey, reason: string(d.Category)})
	filed := s.Reports.Add(reports.Record{Ref: ref, ClubID: id, Post: post, Category: d.Category, At: now, Reason: reason}) == nil
	if !filed {
		log.Print("reports: record not saved")
	}
	out := map[string]any{"filed": filed, "reasonOutstanding": d.ReasonOutstanding && filed}
	if filed {
		out["ref"] = ref
	}
	writeJSON(w, http.StatusOK, out)
}

// holdReportedClub is the abuse-material path: hold, then end the club. It reports whether the report may
// go on to be filed; when it returns false it has already answered. The club comes down in every case,
// even if the hold could not be made, because the reporter did nothing wrong.
func (s *Server) holdReportedClub(w http.ResponseWriter, r *http.Request, id string, post int, proof, ref string, fulls []string, now time.Time) bool {
	// The club must exist. A post-level report must also carry the read proof; a club that is already
	// disabled still counts (its link can be held), and one that has ended is held for its link alone.
	var err error
	if post > 0 {
		if err = s.Clubs.Check(id, clubs.Read, proof, now); errors.Is(err, clubs.ErrGone) {
			err = nil
		}
	} else {
		err = s.Clubs.Reportable(id, now, true)
	}
	if err != nil {
		clubFailure(w, err)
		return false
	}
	var full []byte
	if len(fulls) == 1 && len(fulls[0]) <= maxReportLink && strings.Contains(fulls[0], "/c/"+id) {
		full = []byte(strings.TrimSpace(fulls[0]))
	}
	perClient := s.HoldsPerClientPerDay
	if perClient <= 0 {
		perClient = 5
	}
	// Only a new hold of a real club spends a client's allowance; a re-report of a held club begins no new
	// hold (its link is added to the held ones, up to the per-item cap).
	var holdErr error
	if !s.Clubs.IsHeld(id) {
		if _, ok := s.holdQuota.reserve(s.clientKey(r), 1, perClient, now); !ok {
			holdErr = clubs.ErrHoldCap
			if err := s.Clubs.NoteHoldRefused(id, "holds today from one client network at the cap of "+strconv.Itoa(perClient), now); err != nil {
				log.Print("reports: cap line could not be written")
			}
		}
	}
	if holdErr == nil {
		holdErr = s.Clubs.Hold(id, "form-"+ref, full, now)
	}
	switch {
	case holdErr == nil:
		return true
	case errors.Is(holdErr, clubs.ErrNotFound):
		clubFailure(w, holdErr)
		return false
	case errors.Is(holdErr, clubs.ErrHoldCap):
		// Not a plain takedown, which would delete the ciphertext a real report needs. The club goes dark and
		// keeps its content for its 30 days. The owner is alerted and decides (docs/legal/cybertipline-
		// runbook.md, "The hold cap").
		if len(full) > 0 {
			if err := s.Clubs.ParkLink(id, full); errors.Is(err, clubs.ErrGone) {
				// The club has already ended, so there is no content to keep and nowhere to park the link.
				// Say so rather than answer as if it were kept; the reporter can send it again.
				log.Print("reports: HOLD CAP REACHED on an ended club, the reported link was not kept; the reporter was asked to retry")
				fail(w, http.StatusServiceUnavailable, "busy")
				return false
			} else if err != nil {
				log.Print("reports: reported link could not be parked")
			}
		}
		log.Print("reports: HOLD CAP REACHED, club disabled and its content kept 30 days; the owner must hold it by hand (see the access log)")
		if err := s.Clubs.Disable(id, now); err != nil {
			log.Print("reports: club could not be disabled")
			fail(w, http.StatusInternalServerError, "internal")
			return false
		}
		return true
	}
	// The hold did its work if the club is already down (only its log line failed). Otherwise it goes dark
	// now and keeps its content, so a retry can still hold it; the reporter is told to try again and the
	// owner's runbook command holds it by hand.
	if !s.Clubs.EndedAndHeld(id) {
		log.Print("reports: hold failed, club disabled without a hold")
		if s.Clubs.Disable(id, now) != nil {
			log.Print("reports: club could not be disabled")
		}
		fail(w, http.StatusInternalServerError, "internal")
		return false
	}
	log.Print("reports: hold finished with an error")
	return true
}

// reportClubReason adds the written reason to a report already filed.
func (s *Server) reportClubReason(w http.ResponseWriter, r *http.Request) {
	clubHeaders(w)
	if !s.clubsOn(w) {
		return
	}
	if s.Reports == nil {
		fail(w, http.StatusServiceUnavailable, "disabled")
		return
	}
	if !s.clubReportWindow.hit(s.clientKey(r), s.Now(), clubReportsPerHour) {
		fail(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxClubReportForm)
	if err := r.ParseForm(); err != nil {
		fail(w, http.StatusBadRequest, "bad_request")
		return
	}
	refs, reasons := r.PostForm["ref"], r.PostForm["reason"]
	if len(refs) != 1 || len(reasons) != 1 {
		fail(w, http.StatusBadRequest, "bad_request")
		return
	}
	switch err := s.Reports.AddClubReason(refs[0], r.PathValue("id"), reasons[0]); {
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
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

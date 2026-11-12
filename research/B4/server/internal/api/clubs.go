package api

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"spokenmargins.dev/bridge/internal/clubs"
	"spokenmargins.dev/bridge/internal/config"
)

// The club mailbox (#1799, docs/design/club-mailbox.md). A club is a box of sealed packets that members
// read and add to with a proof each; the server never has the key. Club requests carry no install
// identity: the proof is the only credential, and the only thing the server keeps about a request is
// the hourly count in the request log, under one route name that holds no id, proof or number.
const (
	PathClubs = "/api/v1/clubs"
	// routeClubs is how the request log names every club request, so a club id, a proof or a post number
	// is never written to disk. routeClubPage is the landing page's, kept for it now (slice 4).
	routeClubs    = "/api/v1/clubs/*"
	routeClubPage = "/c/*"

	// maxClubCreateBody holds a 16 KiB sealed header, base64 in JSON, with room for the ids.
	maxClubCreateBody = 32 << 10

	defaultClubWritesPerIPPerHour       = 30
	defaultClubBytesPerIPPerHour  int64 = 200 << 20
)

func (s *Server) clubsUp() bool {
	doc, err := s.Config.Current()
	return err == nil && doc.Enabled(config.ServiceClubs) && s.Clubs != nil
}

func (s *Server) clubsOn(w http.ResponseWriter) bool {
	if !s.clubsUp() {
		fail(w, http.StatusServiceUnavailable, "disabled")
		return false
	}
	return true
}

func clubHeaders(w http.ResponseWriter) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("X-Robots-Tag", "noindex, nofollow")
}

// isClubRoute is true for every path the clubs own, so the request log names them as one route.
func isClubRoute(path string) (string, bool) {
	switch {
	case path == PathClubs || strings.HasPrefix(path, PathClubs+"/"):
		return routeClubs, true
	case strings.HasPrefix(path, "/c/"):
		return routeClubPage, true
	}
	return "", false
}

// byteWindow is window for bytes: a fixed hour, reset wholesale when it ends.
type byteWindow struct {
	mu     sync.Mutex
	start  time.Time
	counts map[string]int64
}

// reserve takes n bytes from key's hour, or nothing if that would pass limit.
func (w *byteWindow) reserve(key string, n, limit int64, now time.Time) bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.counts == nil || now.Sub(w.start) >= time.Hour {
		w.start, w.counts = now, map[string]int64{}
	}
	if w.counts[key]+n > limit {
		return false
	}
	w.counts[key] += n
	return true
}

// clubProof is the bearer value a member sends: 64 lowercase hex digits. Anything else is "no proof",
// which the store answers like a wrong one.
func clubProof(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if v, ok := strings.CutPrefix(h, "Bearer "); ok {
		return v
	}
	return ""
}

// clubFailure maps the store's answers. A wrong or missing proof, an unknown club and a bad id are all
// "not_found" with one body, so a stranger learns nothing about which ids are clubs. "expired_or_removed"
// goes only to someone who sent the club's proof.
func clubFailure(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, clubs.ErrNotFound):
		fail(w, http.StatusNotFound, "not_found")
	case errors.Is(err, clubs.ErrGone):
		fail(w, http.StatusGone, "expired_or_removed")
	case errors.Is(err, clubs.ErrClubFull):
		fail(w, http.StatusConflict, "club_full")
	case errors.Is(err, clubs.ErrConflict):
		fail(w, http.StatusConflict, "id_in_use")
	case errors.Is(err, clubs.ErrFull):
		fail(w, http.StatusServiceUnavailable, "full")
	case errors.Is(err, clubs.ErrTooLarge):
		fail(w, http.StatusRequestEntityTooLarge, "too_large")
	case errors.Is(err, clubs.ErrUnsealed):
		fail(w, http.StatusBadRequest, "bad_packet")
	case errors.Is(err, clubs.ErrInvalid):
		fail(w, http.StatusBadRequest, "bad_request")
	default:
		fail(w, http.StatusInternalServerError, "internal")
	}
}

func (s *Server) clubWritesPerHour() int {
	if s.ClubWritesPerIPPerHour > 0 {
		return s.ClubWritesPerIPPerHour
	}
	return defaultClubWritesPerIPPerHour
}

func (s *Server) clubBytesPerHour() int64 {
	if s.ClubBytesPerIPPerHour > 0 {
		return s.ClubBytesPerIPPerHour
	}
	return defaultClubBytesPerIPPerHour
}

// createClub is POST /api/v1/clubs with {"id", "readHash", "postHash", "header"}: the club id and the
// SHA-256 of the two proofs, each as lowercase hex, and the sealed header as standard base64. 201 for a
// new club, 200 for a repeat with the same id and hashes (a retry after a lost answer), 409 id_in_use
// for the same id with other hashes.
func (s *Server) createClub(w http.ResponseWriter, r *http.Request) {
	clubHeaders(w)
	if !s.clubsOn(w) {
		return
	}
	now := s.Now()
	if !s.clubWindow.hit(s.clientKey(r), now, s.clubWritesPerHour()) {
		fail(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxClubCreateBody)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	var in struct {
		ID       string `json:"id"`
		ReadHash string `json:"readHash"`
		PostHash string `json:"postHash"`
		Header   string `json:"header"`
	}
	if err := dec.Decode(&in); err != nil {
		var large *http.MaxBytesError
		if errors.As(err, &large) {
			fail(w, http.StatusRequestEntityTooLarge, "too_large")
		} else {
			fail(w, http.StatusBadRequest, "bad_request")
		}
		return
	}
	if dec.More() {
		fail(w, http.StatusBadRequest, "bad_request")
		return
	}
	header, err := base64.StdEncoding.DecodeString(in.Header)
	if err != nil {
		fail(w, http.StatusBadRequest, "bad_request")
		return
	}
	made, err := s.Clubs.Create(in.ID, in.ReadHash, in.PostHash, header, now)
	if err != nil {
		clubFailure(w, err)
		return
	}
	status := http.StatusOK
	if made {
		status = http.StatusCreated
	}
	writeJSON(w, status, map[string]string{"id": in.ID})
}

// postClub is POST /api/v1/clubs/{id}/posts: the post proof as a bearer value and the sealed packet as
// the body. 201 with the post's number.
func (s *Server) postClub(w http.ResponseWriter, r *http.Request) {
	clubHeaders(w)
	if !s.clubsOn(w) {
		return
	}
	now := s.Now()
	key := s.clientKey(r)
	if !s.clubWindow.hit(key, now, s.clubWritesPerHour()) {
		fail(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	id, proof := r.PathValue("id"), clubProof(r)
	// Ask before reading the body, so a stranger cannot make the server buffer a packet.
	if err := s.Clubs.Check(id, clubs.Post, proof, now); err != nil {
		clubFailure(w, err)
		return
	}
	// A declared length over the cap is refused before anything is read or counted.
	if r.ContentLength > clubs.MaxPostBytes {
		fail(w, http.StatusRequestEntityTooLarge, "too_large")
		return
	}
	// One buffered packet at a time, shared with share-link uploads, keeps the service inside its
	// memory limit.
	select {
	case s.linkSlots <- struct{}{}:
		defer func() { <-s.linkSlots }()
	default:
		fail(w, http.StatusServiceUnavailable, "busy")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, clubs.MaxPostBytes)
	packet, err := io.ReadAll(r.Body)
	if err != nil {
		var large *http.MaxBytesError
		if errors.As(err, &large) {
			fail(w, http.StatusRequestEntityTooLarge, "too_large")
		} else {
			fail(w, http.StatusBadRequest, "bad_request")
		}
		return
	}
	// The hour's bytes count what was sent, so a flood of refused posts cannot be repeated for free.
	if !s.clubBytes.reserve(key, int64(len(packet)), s.clubBytesPerHour(), now) {
		fail(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	seq, err := s.Clubs.Post(id, proof, packet, now)
	if err != nil {
		clubFailure(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]int{"seq": seq})
}

// listClubPosts is GET /api/v1/clubs/{id}/posts?after=n with the read proof: [{seq, size}] for every
// post after number n.
func (s *Server) listClubPosts(w http.ResponseWriter, r *http.Request) {
	clubHeaders(w)
	if !s.clubsOn(w) {
		return
	}
	after := 0
	if v := r.URL.Query().Get("after"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 0 {
			fail(w, http.StatusBadRequest, "bad_request")
			return
		}
		after = n
	}
	list, err := s.Clubs.List(r.PathValue("id"), clubProof(r), after, s.Now())
	if err != nil {
		clubFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"posts": list})
}

// getClubItem is GET /api/v1/clubs/{id}/posts/{seq} with the read proof: the sealed bytes, unchanged.
// Number 0 is the club's sealed header.
func (s *Server) getClubItem(w http.ResponseWriter, r *http.Request) {
	clubHeaders(w)
	if !s.clubsOn(w) {
		return
	}
	seq, err := strconv.Atoi(r.PathValue("seq"))
	if err != nil || seq < 0 || strconv.Itoa(seq) != r.PathValue("seq") {
		// A stranger must not be able to tell a bad number from a bad proof, so it is checked as one.
		if err := s.Clubs.Check(r.PathValue("id"), clubs.Read, clubProof(r), s.Now()); err != nil {
			clubFailure(w, err)
			return
		}
		fail(w, http.StatusNotFound, "not_found")
		return
	}
	f, err := s.Clubs.Item(r.PathValue("id"), clubProof(r), seq, s.Now())
	if err != nil {
		clubFailure(w, err)
		return
	}
	defer f.Close()
	w.Header().Set("Content-Type", "application/octet-stream")
	http.ServeContent(w, r, "", time.Time{}, f)
}

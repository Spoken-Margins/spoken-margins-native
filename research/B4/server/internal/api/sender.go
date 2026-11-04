package api

import (
	"crypto/rand"
	"encoding/hex"
	"net/http"
	"sync"
	"time"
)

// The sender side of "Report this link" (#2239). An install that wants to make a share link first asks
// POST /api/v1/links/sender, an attested request with no content. The answer is its standing on the
// strike ladder (package reportrules) and, when sharing is allowed, a one-use permit. The upload then
// carries the permit in X-SM-Link-Permit, and the server ties the new link to the install's keyed hash
// (package senders) until the link expires. Reporting that link later counts toward the ladder.
//
// The upload itself stays unattested, so a multi-megabyte packet is not tied to a signature and the
// attested request carries nothing about what is being shared. The server learns "this install made a
// link, and its id", for the life of the link; it never learns what the link holds.
const (
	PathLinkSender   = "/api/v1/links/sender"
	HeaderLinkPermit = "X-SM-Link-Permit"

	permitLife = 10 * time.Minute
	// maxPermits bounds memory. Past it the oldest permit is dropped, which only costs that
	// install one more round trip.
	maxPermits = 10000
)

// permitBook holds issued permits in memory only: a restart costs a sender one more request.
type permitBook struct {
	mu sync.Mutex
	by map[string]permit
}

type permit struct {
	handle  string
	expires time.Time
}

func (b *permitBook) issue(handle string, now time.Time) (string, time.Time, error) {
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		return "", time.Time{}, err
	}
	token := hex.EncodeToString(raw)
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.by == nil {
		b.by = map[string]permit{}
	}
	for t, p := range b.by {
		if !now.Before(p.expires) {
			delete(b.by, t)
		}
	}
	for len(b.by) >= maxPermits {
		var oldest string
		for t, p := range b.by {
			if oldest == "" || p.expires.Before(b.by[oldest].expires) {
				oldest = t
			}
		}
		delete(b.by, oldest)
	}
	exp := now.Add(permitLife)
	b.by[token] = permit{handle: handle, expires: exp}
	return token, exp, nil
}

func (b *permitBook) peek(token string, now time.Time) (string, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	p, ok := b.by[token]
	if !ok || !now.Before(p.expires) {
		return "", false
	}
	return p.handle, true
}

// take spends a permit: a second take of the same token fails.
func (b *permitBook) take(token string, now time.Time) (string, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	p, ok := b.by[token]
	if !ok {
		return "", false
	}
	delete(b.by, token)
	if !now.Before(p.expires) {
		return "", false
	}
	return p.handle, true
}

// linkSender answers the sender's check. The notice is the same for every category and never names
// one; it is shown once (senders.Store.Check clears it).
func (s *Server) linkSender(w http.ResponseWriter, r *http.Request, _ []byte) {
	linkHeaders(w)
	if !s.linksOn(w) {
		return
	}
	if s.Senders == nil {
		fail(w, http.StatusServiceUnavailable, "disabled")
		return
	}
	keyID, _ := r.Context().Value(attestedKeyID{}).([]byte)
	if len(keyID) == 0 {
		fail(w, http.StatusInternalServerError, "internal")
		return
	}
	now := s.Now()
	handle := s.Senders.Handle(keyID)
	st, err := s.Senders.Check(handle, now)
	if err != nil {
		fail(w, http.StatusInternalServerError, "internal")
		return
	}
	out := map[string]any{"sharingAllowed": st.SharingAllowed, "sharingEnded": st.View.SharingEnded}
	if st.View.Notice != "" {
		out["notice"] = st.View.Notice
	}
	if !st.View.SharingPausedUntil.IsZero() {
		out["sharingPausedUntil"] = st.View.SharingPausedUntil.UTC()
	}
	if st.SharingAllowed {
		token, exp, err := s.permits.issue(handle, now)
		if err != nil {
			fail(w, http.StatusInternalServerError, "internal")
			return
		}
		out["permit"], out["permitExpiresAt"] = token, exp.UTC()
	}
	writeJSON(w, http.StatusOK, out)
}

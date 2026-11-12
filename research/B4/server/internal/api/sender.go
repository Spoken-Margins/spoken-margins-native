package api

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"sync"
	"time"

	"spokenmargins.dev/bridge/internal/devicecheck"
	"spokenmargins.dev/bridge/internal/reportrules"
	"spokenmargins.dev/bridge/internal/senders"
	"spokenmargins.dev/bridge/internal/store"
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

// DeviceChecker is the two-bit store behind the ladder; *devicecheck.Client is the real one.
type DeviceChecker interface {
	Query(ctx context.Context, deviceToken string) (devicecheck.Bits, error)
	Update(ctx context.Context, deviceToken string, b devicecheck.Bits) error
}

// maxDeviceToken bounds what is passed on to Apple. Real tokens are a few KB of base64.
const maxDeviceToken = 16 << 10

// deviceTokenIn reads the optional token from the signed body. ok is false for a body that is not
// the one JSON shape.
func deviceTokenIn(body []byte) (token string, ok bool) {
	if len(body) == 0 {
		return "", true
	}
	var in struct {
		Token string `json:"deviceCheckToken"`
	}
	if json.Unmarshal(body, &in) != nil || len(in.Token) > maxDeviceToken {
		return "", false
	}
	return in.Token, true
}

// reconcileBits brings this server's step and Apple's bits for the device into line (see the package
// comment above). It returns the standing to answer from.
func (s *Server) reconcileBits(ctx context.Context, handle string, st senders.Standing, token string, now time.Time, tag string) (senders.Standing, int, error) {
	bits, err := s.DeviceCheck.Query(ctx, token)
	if err != nil {
		return st, s.deviceCheckFailed(err, now, tag), nil
	}
	remote, ok := reportrules.StepFromBits(bits.Value())
	if !ok {
		return st, 0, nil
	}
	// Apple can take seconds, and a report can land meanwhile: read the standing again before acting on
	// it, and again before answering, so neither the write nor the answer uses a stale step.
	if st, err = s.Senders.Check(handle, now); err != nil {
		return st, http.StatusInternalServerError, err
	}
	switch {
	case remote > st.Step:
		if _, err = s.Senders.Adopt(handle, remote, now); err != nil {
			return st, http.StatusInternalServerError, err
		}
	case st.Step > remote:
		if err := s.DeviceCheck.Update(ctx, token, devicecheck.BitsOf(st.Step.Bits())); err != nil {
			st2, cerr := s.Senders.Check(handle, now)
			return st2, s.deviceCheckFailed(err, now, tag), cerr
		}
	}
	st, err = s.Senders.Check(handle, now)
	if err != nil {
		return st, http.StatusInternalServerError, err
	}
	return st, 0, nil
}

// deviceCheckFailed counts the failure for the hourly abuse log (by install tag, as a rate limit is) and
// returns 400 for a refused token, else 0: fail open.
func (s *Server) deviceCheckFailed(err error, now time.Time, tag string) int {
	reason := "devicecheck_unavailable"
	status := 0
	if errors.Is(err, devicecheck.ErrBadToken) {
		reason, status = "devicecheck_bad_token", http.StatusBadRequest
	}
	s.countAbuse(abuseKey{hour: now.UTC().Format("2006-01-02T15"), tag: tag, reason: reason})
	return status
}

// linkSender answers the sender's check. The notice is the same for every category and never names
// one; it is shown once (senders.Store.Check clears it).
func (s *Server) linkSender(w http.ResponseWriter, r *http.Request, body []byte) {
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
	if s.DeviceCheck != nil && s.Senders.Active() {
		token, ok := deviceTokenIn(body)
		if !ok {
			fail(w, http.StatusBadRequest, "bad_request")
			return
		}
		if token == "" {
			// Nothing else is said, so the notice is not marked shown and waits for the repeat.
			writeJSON(w, http.StatusOK, map[string]any{"deviceCheckWanted": true})
			return
		}
		var status int
		st, status, err = s.reconcileBits(r.Context(), handle, st, token, now, store.Tag(keyID))
		if err != nil {
			fail(w, status, "internal")
			return
		}
		if status != 0 {
			fail(w, status, "bad_device_token")
			return
		}
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
	// Only now, with the answer built, is the notice marked shown.
	if st.View.Notice != "" {
		if err := s.Senders.ClearNotice(handle); err != nil {
			fail(w, http.StatusInternalServerError, "internal")
			return
		}
	}
	writeJSON(w, http.StatusOK, out)
}

package api

import (
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"sync"
	"time"

	"spokenmargins.dev/bridge/internal/config"
	"spokenmargins.dev/bridge/internal/store"
	"spokenmargins.dev/bridge/internal/tokens"
)

const (
	PathTokens    = "/api/v1/tokens"
	PathTokenKeys = "/api/v1/tokens/keys"

	TokenKeysSchema = "spokenmargins.token-keys.v1"

	// tokensPerInstallPerDay is how many anonymous tokens one install may
	// get in a UTC day (DESIGN.md §3 suggests about 10).
	tokensPerInstallPerDay = 10
)

// dayQuota counts tokens per install tag for the current UTC day, in memory
// only, and forgets every count when the day changes. It never learns which
// signature went to which install, only how many.
type dayQuota struct {
	mu     sync.Mutex
	day    string
	counts map[string]int
}

// reserve takes n from tag's allowance, or nothing if that would pass limit.
func (q *dayQuota) reserve(tag string, n, limit int, now time.Time) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	if day := now.UTC().Format("2006-01-02"); q.day != day || q.counts == nil {
		q.day, q.counts = day, map[string]int{}
	}
	if q.counts[tag]+n > limit {
		return false
	}
	q.counts[tag] += n
	return true
}

func (q *dayQuota) refund(tag string, n int) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.counts[tag] -= n; q.counts[tag] <= 0 {
		delete(q.counts, tag)
	}
}

// tokensOn refuses before anything else runs when the tokens switch is off,
// so a switched-off feature doesn't even advance an install's counter.
func (s *Server) tokensOn(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		doc, err := s.Config.Current()
		if err != nil || !doc.Enabled(config.ServiceTokens) || s.Tokens == nil {
			fail(w, http.StatusServiceUnavailable, "disabled")
			return
		}
		next(w, r)
	}
}

type tokenKeyJSON struct {
	ID        string `json:"tokenKeyId"`
	PublicKey string `json:"publicKey"`
	NotBefore string `json:"notBefore"`
	NotAfter  string `json:"notAfter"`
}

// tokenKeys lists the signing keys. The answer is the same for every phone,
// so a phone can compare it with what others see and know it wasn't given a
// key of its own (which would let the server link its tokens).
func (s *Server) tokenKeys(w http.ResponseWriter, r *http.Request) {
	keys, err := s.Tokens.PublicKeys(s.Now())
	if err != nil {
		fail(w, http.StatusInternalServerError, "internal")
		return
	}
	out := make([]tokenKeyJSON, 0, len(keys))
	for _, k := range keys {
		der, err := k.SPKI()
		if err != nil {
			fail(w, http.StatusInternalServerError, "internal")
			return
		}
		out = append(out, tokenKeyJSON{
			ID:        hex.EncodeToString(k.ID[:]),
			PublicKey: base64.StdEncoding.EncodeToString(der),
			NotBefore: k.NotBefore.Format(time.RFC3339),
			NotAfter:  k.NotAfter.Format(time.RFC3339),
		})
	}
	w.Header().Set("Cache-Control", "public, max-age=300")
	writeJSON(w, http.StatusOK, map[string]any{
		"schema": TokenKeysSchema, "tokenType": tokens.TokenType, "issuer": tokens.IssuerName, "keys": out,
	})
}

type issueRequest struct {
	KeyID   string   `json:"tokenKeyId"`
	Blinded []string `json:"blindedMessages"`
}

// issueTokens blind-signs up to 10 messages for an attested install. The
// install is known here, but what it will spend the tokens on is not.
func (s *Server) issueTokens(w http.ResponseWriter, r *http.Request, body []byte) {
	var req issueRequest
	if err := json.Unmarshal(body, &req); err != nil {
		fail(w, http.StatusBadRequest, "bad_request")
		return
	}
	var keyID [32]byte
	if b, err := hex.DecodeString(req.KeyID); err != nil || len(b) != len(keyID) {
		fail(w, http.StatusBadRequest, "bad_request")
		return
	} else {
		copy(keyID[:], b)
	}
	if len(req.Blinded) == 0 || len(req.Blinded) > tokens.MaxPerRequest {
		fail(w, http.StatusBadRequest, "bad_request")
		return
	}
	blinded := make([][]byte, len(req.Blinded))
	for n, b64 := range req.Blinded {
		b, err := base64.StdEncoding.DecodeString(b64)
		if err != nil {
			fail(w, http.StatusBadRequest, "bad_request")
			return
		}
		blinded[n] = b
	}

	keyIDHeader, _ := base64.StdEncoding.DecodeString(r.Header.Get(HeaderKeyID))
	tag, now := store.Tag(keyIDHeader), s.Now()
	if !s.tokenQuota.reserve(tag, len(blinded), tokensPerInstallPerDay, now) {
		s.countAbuse(abuseKey{hour: now.UTC().Format("2006-01-02T15"), tag: tag, reason: "token_quota"})
		fail(w, http.StatusTooManyRequests, "quota")
		return
	}
	sigs, err := s.Tokens.Sign(now, keyID, blinded)
	if err != nil {
		s.tokenQuota.refund(tag, len(blinded))
		switch {
		case errors.Is(err, tokens.ErrStaleKey):
			fail(w, http.StatusConflict, "stale_key")
		case errors.Is(err, tokens.ErrInvalidInput), errors.Is(err, tokens.ErrTooMany):
			fail(w, http.StatusBadRequest, "bad_request")
		default:
			fail(w, http.StatusInternalServerError, "internal")
		}
		return
	}
	out := make([]string, len(sigs))
	for n, sig := range sigs {
		out[n] = base64.StdEncoding.EncodeToString(sig)
	}
	writeJSON(w, http.StatusOK, map[string]any{"tokenKeyId": req.KeyID, "blindSignatures": out})
}

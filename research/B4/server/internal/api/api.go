// Package api is the HTTP surface of the Spoken Margins server (seam I11).
//
// Privacy rules this file enforces, not just documents:
//   - The request log holds the hour, route, status and a latency bucket.
//     Never an IP address, key id, install tag, header, query or body.
//   - Client IPs are used only in memory, keyed through an HMAC with a
//     per-process secret, for rate limiting the unauthenticated endpoints.
//   - The abuse log holds hour, install tag and reason, and only for
//     over-limit installs, so the owner has something to block.
//   - Public documents (config, bridge manifest) are identical for everyone
//     and need no attestation, so fetching them reveals nothing but "an app
//     is running".
package api

import (
	"bytes"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"spokenmargins.dev/bridge/internal/appattest"
	"spokenmargins.dev/bridge/internal/config"
	"spokenmargins.dev/bridge/internal/store"
)

// Version is reported by the health check.
const Version = "0.1.0-m1"

const (
	HeaderKeyID     = "X-SM-Key-Id"
	HeaderAssertion = "X-SM-Assertion"
	HeaderTime      = "X-SM-Time"

	clientDataPrefix = "spokenmargins-assertion-v1"
	maxClockSkew     = 5 * time.Minute
	challengeTTL     = 5 * time.Minute
	maxChallenges    = 10000
	maxRegisterBody  = 32 << 10
	maxAttestedBody  = 64 << 10

	// Public paths, relative to both the URL root and PublicDir.
	PathConfig   = "/api/v1/config.json"
	PathManifest = "/bridge/v1/manifest.json"
)

// ClientData is what the app signs for an attested request. It binds the
// assertion to the method, path, time and exact body, so a captured
// assertion can't be reused for a different request.
func ClientData(method, path string, unix int64, body []byte) []byte {
	h := sha256.Sum256(body)
	return []byte(strings.Join([]string{clientDataPrefix, method, path, strconv.FormatInt(unix, 10), hex.EncodeToString(h[:])}, "\n"))
}

type Server struct {
	Verifier  *appattest.Verifier
	Store     *store.Store
	Config    *config.Reader
	PublicDir string
	// RequestLog and AbuseLog receive JSON lines. Nil discards.
	RequestLog io.Writer
	AbuseLog   io.Writer
	// TrustForwardedFor uses X-Forwarded-For from a loopback peer (Caddy on
	// the same box) as the client address for rate limiting.
	TrustForwardedFor bool
	Now               func() time.Time

	// Per-hour limits. Zero means the defaults below.
	ChallengesPerIPPerHour  int
	RequestsPerInstallPerHr int

	once       sync.Once
	ipSecret   []byte
	mu         sync.Mutex
	challenges map[string]time.Time
	ipWindow   window
	keyWindow  window
	logMu      sync.Mutex
}

func (s *Server) init() {
	s.once.Do(func() {
		s.ipSecret = make([]byte, 32)
		if _, err := rand.Read(s.ipSecret); err != nil {
			panic(err)
		}
		s.challenges = map[string]time.Time{}
		if s.Now == nil {
			s.Now = time.Now
		}
		if s.ChallengesPerIPPerHour == 0 {
			s.ChallengesPerIPPerHour = 30
		}
		if s.RequestsPerInstallPerHr == 0 {
			s.RequestsPerInstallPerHr = 120
		}
	})
}

// window is a fixed one-hour counter, reset wholesale when the hour ends,
// so nothing about a client outlives the hour it was counted in.
type window struct {
	mu     sync.Mutex
	start  time.Time
	counts map[string]int
}

func (w *window) hit(key string, now time.Time, limit int) bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.counts == nil || now.Sub(w.start) >= time.Hour {
		w.start, w.counts = now, map[string]int{}
	}
	w.counts[key]++
	return w.counts[key] <= limit
}

func (s *Server) Handler() http.Handler {
	s.init()
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/health", s.health)
	mux.HandleFunc("GET "+PathConfig, s.public(PathConfig))
	mux.HandleFunc("GET "+PathManifest, s.public(PathManifest))
	mux.HandleFunc("POST /api/v1/attest/challenge", s.challenge)
	mux.HandleFunc("POST /api/v1/attest/register", s.register)
	mux.HandleFunc("POST /api/v1/ping", s.attested(s.ping))
	return s.logRequests(mux)
}

// Routes the request log may name. Anything else is logged as "other", so a
// probe for /api/v1/users/alice never writes "alice" to disk.
var loggedRoutes = map[string]bool{
	"/api/v1/health": true, PathConfig: true, PathManifest: true,
	"/api/v1/attest/challenge": true, "/api/v1/attest/register": true, "/api/v1/ping": true,
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func latencyBucket(d time.Duration) string {
	switch {
	case d < 50*time.Millisecond:
		return "under50ms"
	case d < 500*time.Millisecond:
		return "under500ms"
	default:
		return "over500ms"
	}
}

func (s *Server) logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		route := r.URL.Path
		if !loggedRoutes[route] {
			route = "other"
		}
		defer func() {
			// net/http's own panic message names the peer address, so recover
			// here and log only the route.
			if p := recover(); p != nil {
				s.writeLine(s.RequestLog, map[string]any{"hour": s.Now().UTC().Format("2006-01-02T15"), "route": route, "panic": fmt.Sprint(p)})
				fail(rec, http.StatusInternalServerError, "internal")
			}
		}()
		next.ServeHTTP(rec, r)
		s.writeLine(s.RequestLog, map[string]any{
			"hour":    s.Now().UTC().Format("2006-01-02T15"),
			"method":  r.Method,
			"route":   route,
			"status":  rec.status,
			"latency": latencyBucket(time.Since(start)),
		})
	})
}

func (s *Server) writeLine(w io.Writer, v map[string]any) {
	if w == nil {
		return
	}
	line, _ := json.Marshal(v)
	s.logMu.Lock()
	defer s.logMu.Unlock()
	w.Write(append(line, '\n'))
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func fail(w http.ResponseWriter, status int, code string) {
	if status == http.StatusServiceUnavailable {
		w.Header().Set("Retry-After", "3600")
	}
	writeJSON(w, status, map[string]string{"error": code})
}

func (s *Server) health(w http.ResponseWriter, r *http.Request) {
	doc, err := s.Config.Current()
	services := map[string]string{}
	for _, name := range config.KnownServices {
		state := "off"
		if err == nil && doc.Enabled(name) {
			state = "on"
		}
		services[name] = state
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "version": Version, "services": services})
}

// public serves one of the documents every install gets identically. The
// ETag is a hash of the content, so it can't act as a per-install cookie.
func (s *Server) public(path string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		data, err := os.ReadFile(filepath.Join(s.PublicDir, filepath.FromSlash(strings.TrimPrefix(path, "/"))))
		if err != nil {
			fail(w, http.StatusNotFound, "not_found")
			return
		}
		sum := sha256.Sum256(data)
		w.Header().Set("ETag", `"`+hex.EncodeToString(sum[:16])+`"`)
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "public, max-age=300")
		http.ServeContent(w, r, "", time.Time{}, bytes.NewReader(data))
	}
}

func (s *Server) enabled(w http.ResponseWriter) bool {
	doc, err := s.Config.Current()
	if err != nil || !doc.Enabled(config.ServiceAttest) {
		fail(w, http.StatusServiceUnavailable, "disabled")
		return false
	}
	return true
}

func (s *Server) clientKey(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	if s.TrustForwardedFor {
		if ip := net.ParseIP(host); ip != nil && ip.IsLoopback() {
			if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
				parts := strings.Split(xff, ",")
				host = strings.TrimSpace(parts[len(parts)-1])
			}
		}
	}
	m := hmac.New(sha256.New, s.ipSecret)
	m.Write([]byte(host))
	return hex.EncodeToString(m.Sum(nil))
}

func (s *Server) challenge(w http.ResponseWriter, r *http.Request) {
	if !s.enabled(w) {
		return
	}
	now := s.Now()
	if !s.ipWindow.hit(s.clientKey(r), now, s.ChallengesPerIPPerHour) {
		fail(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	c := make([]byte, 32)
	if _, err := rand.Read(c); err != nil {
		fail(w, http.StatusInternalServerError, "internal")
		return
	}
	s.mu.Lock()
	for k, exp := range s.challenges {
		if now.After(exp) {
			delete(s.challenges, k)
		}
	}
	if len(s.challenges) >= maxChallenges {
		s.mu.Unlock()
		fail(w, http.StatusServiceUnavailable, "busy")
		return
	}
	s.challenges[string(c)] = now.Add(challengeTTL)
	s.mu.Unlock()
	writeJSON(w, http.StatusOK, map[string]any{
		"challenge":        base64.StdEncoding.EncodeToString(c),
		"expiresInSeconds": int(challengeTTL.Seconds()),
	})
}

// takeChallenge consumes a challenge; each one works once.
func (s *Server) takeChallenge(c []byte) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	exp, ok := s.challenges[string(c)]
	delete(s.challenges, string(c))
	return ok && !s.Now().After(exp)
}

type registerRequest struct {
	KeyID       string `json:"keyId"`
	Challenge   string `json:"challenge"`
	Attestation string `json:"attestation"`
}

func (s *Server) register(w http.ResponseWriter, r *http.Request) {
	if !s.enabled(w) {
		return
	}
	if !s.ipWindow.hit(s.clientKey(r), s.Now(), s.ChallengesPerIPPerHour) {
		fail(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	var req registerRequest
	body := http.MaxBytesReader(w, r.Body, maxRegisterBody)
	dec := json.NewDecoder(body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		fail(w, http.StatusBadRequest, "bad_request")
		return
	}
	keyID, err1 := base64.StdEncoding.DecodeString(req.KeyID)
	challenge, err2 := base64.StdEncoding.DecodeString(req.Challenge)
	att, err3 := base64.StdEncoding.DecodeString(req.Attestation)
	if err1 != nil || err2 != nil || err3 != nil || len(keyID) != sha256.Size {
		fail(w, http.StatusBadRequest, "bad_request")
		return
	}
	if !s.takeChallenge(challenge) {
		fail(w, http.StatusBadRequest, "challenge_expired")
		return
	}
	key, err := s.Verifier.VerifyAttestation(keyID, challenge, att)
	if err != nil {
		fail(w, http.StatusUnauthorized, "invalid_attestation")
		return
	}
	pub, err := appattest.MarshalPublicKey(key.PublicKey)
	if err != nil {
		fail(w, http.StatusInternalServerError, "internal")
		return
	}
	today := s.Now().UTC().Format(store.DayFormat)
	err = s.Store.Register(keyID, store.Install{PublicKey: pub, Environment: key.Environment, CreatedDay: today, LastSeenDay: today})
	switch {
	case errors.Is(err, store.ErrExists):
		fail(w, http.StatusConflict, "already_registered")
	case err != nil:
		fail(w, http.StatusInternalServerError, "internal")
	default:
		// Nothing identifying is returned; the app already knows its key id.
		writeJSON(w, http.StatusCreated, map[string]bool{"registered": true})
	}
}

// attested wraps a feature endpoint: kill switch, assertion, block list and
// per-install rate limit, in that order. The wrapped handler gets the body
// that was signed and never sees the key id.
func (s *Server) attested(h func(http.ResponseWriter, *http.Request, []byte)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !s.enabled(w) {
			return
		}
		keyID, err1 := base64.StdEncoding.DecodeString(r.Header.Get(HeaderKeyID))
		assertion, err2 := base64.StdEncoding.DecodeString(r.Header.Get(HeaderAssertion))
		unix, err3 := strconv.ParseInt(r.Header.Get(HeaderTime), 10, 64)
		if err1 != nil || err2 != nil || err3 != nil || len(keyID) != sha256.Size || len(assertion) == 0 {
			fail(w, http.StatusUnauthorized, "missing_assertion")
			return
		}
		now := s.Now()
		if d := now.Sub(time.Unix(unix, 0)); d > maxClockSkew || d < -maxClockSkew {
			fail(w, http.StatusUnauthorized, "clock_skew")
			return
		}
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxAttestedBody))
		if err != nil {
			fail(w, http.StatusRequestEntityTooLarge, "too_large")
			return
		}
		if s.Store.IsBlocked(keyID) {
			// Deliberately vague: the app stops retrying, an abuser learns little.
			fail(w, http.StatusForbidden, "refused")
			return
		}
		in, err := s.Store.Get(keyID)
		if errors.Is(err, store.ErrNotFound) {
			// The app responds by attesting a new key.
			fail(w, http.StatusUnauthorized, "unknown_key")
			return
		} else if err != nil {
			fail(w, http.StatusInternalServerError, "internal")
			return
		}
		pub, err := appattest.ParsePublicKey(in.PublicKey)
		if err != nil {
			fail(w, http.StatusInternalServerError, "internal")
			return
		}
		counter, err := appattest.VerifyAssertion(s.Verifier.AppID, pub, in.Counter, ClientData(r.Method, r.URL.Path, unix, body), assertion)
		if err != nil {
			fail(w, http.StatusUnauthorized, "invalid_assertion")
			return
		}
		if err := s.Store.Advance(keyID, counter, now); err != nil {
			fail(w, http.StatusUnauthorized, "invalid_assertion")
			return
		}
		tag := store.Tag(keyID)
		if !s.keyWindow.hit(tag, now, s.RequestsPerInstallPerHr) {
			s.writeLine(s.AbuseLog, map[string]any{
				"hour": now.UTC().Format("2006-01-02T15"), "tag": tag, "reason": "rate_limited",
			})
			fail(w, http.StatusTooManyRequests, "rate_limited")
			return
		}
		h(w, r, body)
	}
}

// ping is an attested no-op: it lets the app (and the test client) confirm
// its key is registered and the channel works. It carries no content.
func (s *Server) ping(w http.ResponseWriter, r *http.Request, body []byte) {
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

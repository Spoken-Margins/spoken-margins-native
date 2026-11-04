// Package senders keeps what the strike ladder (#2239, internal/reportrules) needs to know about a
// sender of share links: which links an install made, how many of them were reported, and where the
// install stands on the ladder. It is the server's only link from a share link to anyone, so it keeps
// as little as the ladder can work with:
//
//   - the sender is a keyed hash (HMAC-SHA-256) of the attested install key id, never the key id;
//   - a link is tied to its sender only until the link expires, and the tie is deleted with it;
//   - the sender's file holds link ids, times, the ladder step and one "tell them" flag, and no
//     category, no reporter, no content and no address, so no notice can depend on what was reported;
//   - a clean sender with no reported link inside the 90-day window has no file at all.
//
// The hash key is made once and kept in the state folder, because a pause has to outlive a restart
// (the reporter windows in package reports are memory-only for the opposite reason). A reinstall makes
// a new install key and so a new sender; what survives a reinstall is the DeviceCheck bits, which are
// the app's and Apple's side of #2239 and are not here.
//
// Nothing here reads a report or decides anything from one. The caller says "this link was reported"
// and gets back the new standing.
package senders

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"time"

	"spokenmargins.dev/bridge/internal/reportrules"
)

var (
	// ErrBadID: a link id or sender handle is not the fixed-width lowercase hex the store writes,
	// so it can never name a path outside the store.
	ErrBadID = errors.New("senders: bad id")
	// ErrNoKey: the key file exists but is not a 32-byte key. Opening fails rather than starting
	// a fresh key, which would silently forget every pause.
	ErrNoKey = errors.New("senders: unreadable hash key")
)

const (
	keyFile     = "key"
	sendersDir  = "senders"
	bindingsDir = "bindings"
	handleLen   = 64 // hex of a SHA-256
	linkIDLen   = 32
)

// Store is a folder of small JSON files, rewritten whole and atomically. Reports are rare and uploads
// are rate-limited, so a file per sender and a file per live link stays small.
type Store struct {
	dir string
	key []byte
	mu  sync.Mutex
}

// Open creates the folder (mode 0700) and, the first time, the hash key (mode 0600).
func Open(dir string) (*Store, error) {
	for _, sub := range []string{sendersDir, bindingsDir} {
		if err := os.MkdirAll(filepath.Join(dir, sub), 0o700); err != nil {
			return nil, err
		}
	}
	keyPath := filepath.Join(dir, keyFile)
	key, err := os.ReadFile(keyPath)
	switch {
	case errors.Is(err, os.ErrNotExist):
		key = make([]byte, 32)
		if _, err := rand.Read(key); err != nil {
			return nil, err
		}
		if err := writeAtomic(keyPath, key, 0o600); err != nil {
			return nil, err
		}
	case err != nil:
		return nil, err
	case len(key) != 32:
		return nil, ErrNoKey
	}
	return &Store{dir: dir, key: key}, nil
}

// Handle is the keyed hash of an attested install key id: the only name a sender has here.
func (s *Store) Handle(keyID []byte) string {
	m := hmac.New(sha256.New, s.key)
	m.Write([]byte("sender"))
	m.Write([]byte{0})
	m.Write(keyID)
	return hex.EncodeToString(m.Sum(nil))
}

// Standing is what the sender's next check learns. View is built from state that holds no category.
type Standing struct {
	View reportrules.SenderView
	// SharingAllowed: may this sender make a link now?
	SharingAllowed bool
}

// Outcome is what a recorded report did.
type Outcome struct {
	// Bound is false when the link has no sender (it was made without a permit). Then nothing is kept.
	Bound bool
	// Counted and Struck are reportrules.StrikeResult.
	Counted, Struck bool
	Step            reportrules.Step
}

// Bind ties a new link to its sender until the link expires.
func (s *Store) Bind(linkID, handle string, until time.Time) error {
	if !hexOf(linkID, linkIDLen) || !hexOf(handle, handleLen) {
		return ErrBadID
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	data, err := json.Marshal(binding{Sender: handle, Until: until.UTC()})
	if err != nil {
		return err
	}
	return writeAtomic(filepath.Join(s.dir, bindingsDir, linkID+".json"), data, 0o600)
}

// Report records that a link was reported and taken down. cfg is the ladder; now is the report time.
// A link with no sender changes nothing. The sender is told on their next Check.
func (s *Store) Report(cfg reportrules.Config, linkID string, now time.Time) (Outcome, error) {
	if !hexOf(linkID, linkIDLen) {
		return Outcome{}, ErrBadID
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	var b binding
	if err := readJSON(filepath.Join(s.dir, bindingsDir, linkID+".json"), &b); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return Outcome{}, nil
		}
		return Outcome{}, err
	}
	if !hexOf(b.Sender, handleLen) {
		return Outcome{}, ErrBadID
	}
	rec, err := s.load(b.Sender)
	if err != nil {
		return Outcome{}, err
	}
	st, res := cfg.RecordReportedLink(rec.state(), linkID, now)
	rec.set(st)
	rec.NoticePending = true
	if err := s.save(b.Sender, rec); err != nil {
		return Outcome{}, err
	}
	return Outcome{Bound: true, Counted: res.Counted, Struck: res.Struck, Step: st.Step}, nil
}

// Check is the sender's next check: it returns their standing and clears the takedown notice, so the
// notice is shown once. A sender with no file is clean.
func (s *Store) Check(handle string, now time.Time) (Standing, error) {
	if !hexOf(handle, handleLen) {
		return Standing{}, ErrBadID
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	rec, err := s.load(handle)
	if err != nil {
		return Standing{}, err
	}
	st := rec.state()
	out := Standing{View: reportrules.ViewFor(st, rec.NoticePending, now), SharingAllowed: st.SharingAllowed(now)}
	if rec.NoticePending {
		rec.NoticePending = false
		if err := s.save(handle, rec); err != nil {
			return Standing{}, err
		}
	}
	return out, nil
}

// Allowed reports whether the sender may make a link now, without touching the notice.
func (s *Store) Allowed(handle string, now time.Time) (bool, error) {
	if !hexOf(handle, handleLen) {
		return false, ErrBadID
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	rec, err := s.load(handle)
	if err != nil {
		return false, err
	}
	return rec.state().SharingAllowed(now), nil
}

// Sweep deletes ties for links that have expired, drops reported links older than the strike window,
// and deletes a sender's file once nothing in it matters: step clean, no link inside the window, no
// pause running, no notice waiting. A sender on the ladder keeps their file; the step does not decay.
// It returns how many files it deleted.
func (s *Store) Sweep(cfg reportrules.Config, now time.Time) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	deleted := 0
	binds, err := os.ReadDir(filepath.Join(s.dir, bindingsDir))
	if err != nil {
		return 0, err
	}
	for _, e := range binds {
		var b binding
		p := filepath.Join(s.dir, bindingsDir, e.Name())
		if readJSON(p, &b) != nil || now.After(b.Until) {
			if os.Remove(p) == nil {
				deleted++
			}
		}
	}
	files, err := os.ReadDir(filepath.Join(s.dir, sendersDir))
	if err != nil {
		return deleted, err
	}
	for _, e := range files {
		handle := e.Name()
		if len(handle) != handleLen+len(".json") || !hexOf(handle[:handleLen], handleLen) {
			continue
		}
		handle = handle[:handleLen]
		rec, err := s.load(handle)
		if err != nil {
			continue
		}
		kept := rec.Links[:0:0]
		for _, l := range rec.Links {
			if now.Sub(l.At) <= cfg.StrikeWindow {
				kept = append(kept, l)
			}
		}
		changed := len(kept) != len(rec.Links)
		rec.Links = kept
		if reportrules.Step(rec.Step) == reportrules.StepClean && len(kept) == 0 && !rec.NoticePending && !now.Before(rec.PausedUntil) {
			if os.Remove(filepath.Join(s.dir, sendersDir, handle+".json")) == nil {
				deleted++
			}
			continue
		}
		if changed {
			if err := s.save(handle, rec); err != nil {
				return deleted, err
			}
		}
	}
	return deleted, nil
}

type binding struct {
	Sender string    `json:"sender"`
	Until  time.Time `json:"until"`
}

type linkJSON struct {
	ID   string    `json:"id"`
	At   time.Time `json:"at"`
	Used bool      `json:"used,omitempty"`
}

// record is a sender's file. It has no field for a category, a reporter or a link's content.
type record struct {
	Step          uint8      `json:"step"`
	Links         []linkJSON `json:"links,omitempty"`
	PausedUntil   time.Time  `json:"pausedUntil,omitempty"`
	NoticePending bool       `json:"notice,omitempty"`
}

func (r *record) state() reportrules.SenderState {
	st := reportrules.SenderState{Step: reportrules.Step(r.Step), PausedUntil: r.PausedUntil}
	for _, l := range r.Links {
		st.Links = append(st.Links, reportrules.ReportedLink{ID: l.ID, At: l.At, Used: l.Used})
	}
	return st
}

func (r *record) set(st reportrules.SenderState) {
	r.Step, r.PausedUntil, r.Links = st.Step.Bits(), st.PausedUntil.UTC(), nil
	if st.PausedUntil.IsZero() {
		r.PausedUntil = time.Time{}
	}
	for _, l := range st.Links {
		r.Links = append(r.Links, linkJSON{ID: l.ID, At: l.At.UTC(), Used: l.Used})
	}
}

func (s *Store) load(handle string) (*record, error) {
	var r record
	if err := readJSON(filepath.Join(s.dir, sendersDir, handle+".json"), &r); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return &record{}, nil
		}
		return nil, err
	}
	return &r, nil
}

func (s *Store) save(handle string, r *record) error {
	data, err := json.Marshal(r)
	if err != nil {
		return err
	}
	return writeAtomic(filepath.Join(s.dir, sendersDir, handle+".json"), data, 0o600)
}

func readJSON(path string, v any) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, v)
}

func hexOf(s string, n int) bool {
	if len(s) != n {
		return false
	}
	for _, c := range s {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

func writeAtomic(path string, data []byte, mode os.FileMode) error {
	f, err := os.CreateTemp(filepath.Dir(path), ".tmp-")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if err := f.Chmod(mode); err != nil {
		f.Close()
		return err
	}
	if _, err := f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(f.Name(), path)
}

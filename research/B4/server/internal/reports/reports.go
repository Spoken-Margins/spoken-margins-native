// Package reports keeps the record of "Report this link" submissions (#2239, requirement 9):
// the link id, the category, the date, the reporter's written reason when one was given, and a keyed
// hash of the reporter's handle. Nothing else about the reporter is kept, and nothing about the
// reported content: the server cannot read it and nobody opens it.
//
// The handle hash exists so the "second report within 7 days owes a written reason" rule can be
// counted. It is an HMAC under a key generated on first start and kept beside the records, so the same
// phone or network is the same hash across restarts but the hash means nothing without the key. It is
// cleared from a record once the 7-day window has passed, and the whole record goes after 90 days.
package reports

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"spokenmargins.dev/bridge/internal/reportrules"
)

const (
	recordsFile = "reports.json"
	keyFile     = "reporter.key"

	// MaxReasonBytes bounds a written reason. Any length counts, even one character; this is only a
	// ceiling so a form post cannot fill the disk.
	MaxReasonBytes = 2000
)

var (
	ErrNotFound      = errors.New("reports: no such report")
	ErrReasonGiven   = errors.New("reports: this report already has a reason")
	ErrReasonMissing = errors.New("reports: a reason needs some text")
	ErrReasonTooLong = errors.New("reports: reason too long")
)

// Record is one filed report. Reporter is empty once the handle window has passed.
type Record struct {
	Ref      string               `json:"ref"`
	LinkID   string               `json:"link"`
	Category reportrules.Category `json:"category"`
	At       time.Time            `json:"at"`
	Reason   string               `json:"reason,omitempty"`
	Reporter string               `json:"reporter,omitempty"`
}

// Store is a small JSON file of records. Reports are rare and the file is bounded by the 90-day
// sweep and the per-client rate limit, so it is rewritten whole, atomically, on every change.
type Store struct {
	dir string
	key []byte
	mu  sync.Mutex
}

// Open creates the directory (mode 0700) and the handle key on first use.
func Open(dir string) (*Store, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	path := filepath.Join(dir, keyFile)
	key, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		key = make([]byte, 32)
		if _, err := rand.Read(key); err != nil {
			return nil, err
		}
		if err := writeAtomic(dir, keyFile, key); err != nil {
			return nil, err
		}
	} else if err != nil {
		return nil, err
	}
	if len(key) != 32 {
		return nil, errors.New("reports: unreadable handle key")
	}
	s := &Store{dir: dir, key: key}
	if _, err := s.load(); err != nil {
		return nil, err
	}
	return s, nil
}

// Handle is the keyed hash of what identifies a reporter (a client network, or a reply email).
// Kind separates the two so an address and an email cannot collide.
func (s *Store) Handle(kind, value string) string {
	m := hmac.New(sha256.New, s.key)
	m.Write([]byte(kind))
	m.Write([]byte{0})
	m.Write([]byte(value))
	return hex.EncodeToString(m.Sum(nil))
}

const refAlphabet = "23456789ABCDEFGHJKMNPQRSTUVWXYZ" // 31 characters: no 0, O, 1, I or L

// NewRef returns a reference number to read out or write down: 12 characters from an alphabet
// without 0, O, 1, I or L. It is random, so it says nothing about the link or the reporter.
func NewRef() (string, error) {
	out := make([]byte, 0, 12)
	buf := make([]byte, 32)
	for len(out) < 12 {
		if _, err := rand.Read(buf); err != nil {
			return "", err
		}
		for _, b := range buf {
			// 248 is 8 x 31, so the characters come out evenly.
			if b < 248 && len(out) < 12 {
				out = append(out, refAlphabet[int(b)%len(refAlphabet)])
			}
		}
	}
	return string(out), nil
}

// Prior returns the times of this handle's earlier reports that are still inside window, for
// reportrules.Config.Intake. It never returns content.
func (s *Store) Prior(handle string, now time.Time, window time.Duration) ([]time.Time, error) {
	if handle == "" {
		return nil, nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	recs, err := s.load()
	if err != nil {
		return nil, err
	}
	var out []time.Time
	for _, r := range recs {
		if r.Reporter == handle && !now.Before(r.At) && now.Sub(r.At) <= window {
			out = append(out, r.At)
		}
	}
	return out, nil
}

// Add files a record.
func (s *Store) Add(r Record) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	recs, err := s.load()
	if err != nil {
		return err
	}
	r.Reason = strings.TrimSpace(r.Reason)
	return s.save(append(recs, r))
}

// AddReason attaches the written reason to a filed report, once. The ref and the link id must both
// match, so a ref from one link's page cannot be used on another's.
func (s *Store) AddReason(ref, linkID, reason string) error {
	reason = strings.TrimSpace(reason)
	if reason == "" {
		return ErrReasonMissing
	}
	if len(reason) > MaxReasonBytes {
		return ErrReasonTooLong
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	recs, err := s.load()
	if err != nil {
		return err
	}
	for i := range recs {
		if recs[i].Ref == ref && recs[i].LinkID == linkID {
			if recs[i].Reason != "" {
				return ErrReasonGiven
			}
			recs[i].Reason = reason
			return s.save(recs)
		}
	}
	return ErrNotFound
}

// Sweep clears reporter handles older than handleKeep and deletes records older than recordKeep.
// It returns how many records it deleted.
func (s *Store) Sweep(now time.Time, handleKeep, recordKeep time.Duration) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	recs, err := s.load()
	if err != nil {
		return 0, err
	}
	kept := recs[:0:0]
	for _, r := range recs {
		age := now.Sub(r.At)
		if age > recordKeep {
			continue
		}
		if age > handleKeep {
			r.Reporter = ""
		}
		kept = append(kept, r)
	}
	deleted := len(recs) - len(kept)
	if deleted == 0 && !changedHandles(recs, kept) {
		return 0, nil
	}
	return deleted, s.save(kept)
}

func changedHandles(a, b []Record) bool {
	if len(a) != len(b) {
		return true
	}
	for i := range a {
		if a[i].Reporter != b[i].Reporter {
			return true
		}
	}
	return false
}

func (s *Store) load() ([]Record, error) {
	data, err := os.ReadFile(filepath.Join(s.dir, recordsFile))
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var recs []Record
	if err := json.Unmarshal(data, &recs); err != nil {
		return nil, errors.New("reports: unreadable records")
	}
	return recs, nil
}

func (s *Store) save(recs []Record) error {
	data, err := json.Marshal(recs)
	if err != nil {
		return err
	}
	return writeAtomic(s.dir, recordsFile, data)
}

func writeAtomic(dir, name string, data []byte) error {
	f, err := os.CreateTemp(dir, ".tmp-")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
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
	return os.Rename(f.Name(), filepath.Join(dir, name))
}

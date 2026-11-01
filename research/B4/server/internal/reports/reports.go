// Package reports keeps the record of "Report this link" submissions (#2239, requirement 9):
// the link id, the category, the date, and the reporter's written reason when one was given. Nothing
// else about the reporter is kept, and nothing about the reported content: the server cannot read it
// and nobody opens it.
//
// The "second report within 7 days owes a written reason" rule needs to tell one reporter's reports
// apart. That is done in memory only: a keyed hash of the reporter's network, under a key made at start,
// with the report times kept for the window. None of it is written to disk, so no address, and nothing
// that could be turned back into one, is ever stored. The cost is that a restart forgets the window: a
// reporter's second report just after a restart does not owe a reason. Records on disk go after 90 days.
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
	"regexp"
	"strings"
	"sync"
	"time"

	"spokenmargins.dev/bridge/internal/reportrules"
)

const (
	recordsFile = "reports.json"

	// MaxReasonBytes bounds a written reason. Any length counts, even one character; this is only a
	// ceiling so a form post cannot fill the disk. The form's 2000-character box fits under it even
	// in three-byte characters.
	MaxReasonBytes = 6000
)

var (
	ErrNotFound      = errors.New("reports: no such report")
	ErrReasonGiven   = errors.New("reports: this report already has a reason")
	ErrReasonMissing = errors.New("reports: a reason needs some text")
	ErrReasonTooLong = errors.New("reports: reason too long")
)

// Record is one filed report.
type Record struct {
	Ref      string               `json:"ref"`
	LinkID   string               `json:"link"`
	Category reportrules.Category `json:"category"`
	At       time.Time            `json:"at"`
	Reason   string               `json:"reason,omitempty"`
}

// Store is a small JSON file of records plus the in-memory reporter windows. Reports are rare and the
// file is bounded by the 90-day sweep and the per-client rate limit, so it is rewritten whole,
// atomically, on every change.
type Store struct {
	dir    string
	key    []byte // memory only
	mu     sync.Mutex
	recent map[string][]time.Time // handle -> times of its reports; memory only
}

// Open creates the directory (mode 0700) and checks any records already there.
func Open(dir string) (*Store, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return nil, err
	}
	s := &Store{dir: dir, key: key, recent: map[string][]time.Time{}}
	if _, err := s.load(); err != nil {
		return nil, err
	}
	return s, nil
}

// Handle is the keyed hash of what identifies a reporter (a client network, or a reply email), under
// a key that exists only in this process. Kind separates the two so an address and an email cannot
// collide.
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

// Note returns the times of this handle's earlier reports that are still inside window, for
// reportrules.Config.Intake, and records one at now, in one step, so reports sent at the same moment
// cannot each see an empty history. Memory only.
func (s *Store) Note(handle string, now time.Time, window time.Duration) []time.Time {
	s.mu.Lock()
	defer s.mu.Unlock()
	var prior []time.Time
	for _, t := range s.recent[handle] {
		if !now.Before(t) && now.Sub(t) <= window {
			prior = append(prior, t)
		}
	}
	s.recent[handle] = append(append([]time.Time(nil), prior...), now)
	return prior
}

// Add files a record.
func (s *Store) Add(r Record) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	recs, err := s.load()
	if err != nil {
		return err
	}
	r.Reason = cleanReason(r.Category, r.Reason)
	return s.save(append(recs, r))
}

// AddReason attaches the written reason to a filed report, once. The ref and the link id must both
// match, so a ref from one link's page cannot be used on another's.
func (s *Store) AddReason(ref, linkID, reason string) error {
	reason = strings.TrimSpace(reason)
	if len(reason) > MaxReasonBytes {
		return ErrReasonTooLong
	}
	if reason == "" {
		return ErrReasonMissing
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
			recs[i].Reason = cleanReason(recs[i].Category, reason)
			return s.save(recs)
		}
	}
	return ErrNotFound
}

// Sweep deletes records older than recordKeep and forgets reporter windows older than handleKeep.
// It returns how many records it deleted.
func (s *Store) Sweep(now time.Time, handleKeep, recordKeep time.Duration) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for h, times := range s.recent {
		kept := times[:0:0]
		for _, t := range times {
			if now.Sub(t) <= handleKeep {
				kept = append(kept, t)
			}
		}
		if len(kept) == 0 {
			delete(s.recent, h)
		} else {
			s.recent[h] = kept
		}
	}
	recs, err := s.load()
	if err != nil {
		return 0, err
	}
	kept := recs[:0:0]
	for _, r := range recs {
		if now.Sub(r.At) <= recordKeep {
			kept = append(kept, r)
		}
	}
	if len(kept) == len(recs) {
		return 0, nil
	}
	return len(recs) - len(kept), s.save(kept)
}

// linkWithKey matches a pasted share link or its tail: anything ending in /l/<32 hex> followed by # and
// the key. A reason is free text, so outside the abuse-material category a link pasted into it must not
// carry the key to disk.
var linkWithKey = regexp.MustCompile(`\S*/l/[0-9a-f]{32}#\S*`)

// cleanReason trims a reason and, for every category but abuse-material, replaces a pasted link that
// carries a key with a marker. Only an abuse-material report may keep the key, and it keeps it in the
// hold, not here.
func cleanReason(c reportrules.Category, reason string) string {
	reason = strings.TrimSpace(reason)
	if c.CarriesKey() {
		return reason
	}
	return linkWithKey.ReplaceAllString(reason, "[link removed]")
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

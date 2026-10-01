// Package store keeps the only per-install state the server holds: the
// attested public key, its assertion counter, which environment issued it,
// and two dates at day precision so idle records can expire. There is no
// name, email, IP address, device model, follow list or reading history, and
// no field to put one in.
//
// Each install is one small JSON file named by the SHA-256 of its key id, so
// writes are atomic renames and the store needs no database. Blocking lives
// in a separate directory that only the owner's CLI writes, so a request in
// flight can never overwrite a block.
package store

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

var (
	ErrNotFound        = errors.New("store: install not found")
	ErrExists          = errors.New("store: install already registered")
	ErrStaleCounter    = errors.New("store: counter did not increase")
	errBadTag          = errors.New("store: a tag is 16 lowercase hex characters")
	tagPattern         = regexp.MustCompile(`^[0-9a-f]{16}$`)
	installFilePattern = regexp.MustCompile(`^[0-9a-f]{64}\.json$`)
)

const DayFormat = "2006-01-02"

// Install is one attested app install.
type Install struct {
	PublicKey   []byte `json:"publicKey"` // uncompressed P-256 point
	Counter     uint32 `json:"counter"`
	Environment string `json:"environment"`
	CreatedDay  string `json:"createdDay"`
	LastSeenDay string `json:"lastSeenDay"`
}

type Store struct {
	dir string
	mu  sync.Mutex
	// pending holds records changed since the last Flush, keyed by the hex
	// hash of the key id. Writing them in one hourly batch means a record's
	// file times say at most "active in this hour", never the second of a
	// request, which would let a log or a later feature be matched by time.
	pending map[string]*Install
}

func Open(dir string) (*Store, error) {
	for _, sub := range []string{"installs", "blocked"} {
		if err := os.MkdirAll(filepath.Join(dir, sub), 0o700); err != nil {
			return nil, err
		}
	}
	return &Store{dir: dir, pending: map[string]*Install{}}, nil
}

func hashHex(keyID []byte) string {
	h := sha256.Sum256(keyID)
	return hex.EncodeToString(h[:])
}

// Tag is the short handle the owner uses to block an install. It is derived
// from the key id, which is itself a hash of a random per-install key, so it
// identifies an install to this server only.
func Tag(keyID []byte) string { return hashHex(keyID)[:16] }

func (s *Store) path(keyID []byte) string {
	return filepath.Join(s.dir, "installs", hashHex(keyID)+".json")
}

func writeAtomic(path string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".tmp-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

func (s *Store) read(keyID []byte) (*Install, error) {
	if in, ok := s.pending[hashHex(keyID)]; ok {
		c := *in
		return &c, nil
	}
	data, err := os.ReadFile(s.path(keyID))
	if errors.Is(err, os.ErrNotExist) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	var in Install
	if err := json.Unmarshal(data, &in); err != nil {
		return nil, fmt.Errorf("store: corrupt record: %w", err)
	}
	return &in, nil
}

func (s *Store) write(keyID []byte, in *Install) {
	c := *in
	s.pending[hashHex(keyID)] = &c
}

// Flush writes every changed record, then sets each file's access and
// modification times to midnight UTC of its last-seen day. The server calls
// it hourly and on shutdown. A crash loses at most an hour of counter
// advances; replaying an assertion from that hour would still need the
// attacker to have broken TLS to capture it.
func (s *Store) Flush() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for h, in := range s.pending {
		data, err := json.Marshal(in)
		if err != nil {
			return err
		}
		p := filepath.Join(s.dir, "installs", h+".json")
		if err := writeAtomic(p, data); err != nil {
			return err
		}
		if day, err := time.Parse(DayFormat, in.LastSeenDay); err == nil {
			os.Chtimes(p, day, day)
		}
		delete(s.pending, h)
	}
	return nil
}

func (s *Store) Get(keyID []byte) (*Install, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.read(keyID)
}

// Register stores a newly attested key.
func (s *Store) Register(keyID []byte, in Install) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, err := s.read(keyID); err == nil {
		return ErrExists
	} else if !errors.Is(err, ErrNotFound) {
		return err
	}
	s.write(keyID, &in)
	return nil
}

// Advance records a verified assertion's counter. It re-checks the counter
// under the lock so two concurrent copies of one assertion can't both pass.
func (s *Store) Advance(keyID []byte, counter uint32, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	in, err := s.read(keyID)
	if err != nil {
		return err
	}
	if counter <= in.Counter {
		return ErrStaleCounter
	}
	in.Counter = counter
	in.LastSeenDay = now.UTC().Format(DayFormat)
	s.write(keyID, in)
	return nil
}

func (s *Store) blockPath(tag string) string { return filepath.Join(s.dir, "blocked", tag) }

func (s *Store) IsBlocked(keyID []byte) bool {
	_, err := os.Stat(s.blockPath(Tag(keyID)))
	return err == nil
}

// Block refuses every future request from the install with this tag. It
// works for tags not (or no longer) registered, so a block can't be undone
// by the record expiring.
func (s *Store) Block(tag string) error {
	tag = strings.ToLower(strings.TrimSpace(tag))
	if !tagPattern.MatchString(tag) {
		return errBadTag
	}
	return writeAtomic(s.blockPath(tag), nil)
}

func (s *Store) Unblock(tag string) error {
	tag = strings.ToLower(strings.TrimSpace(tag))
	if !tagPattern.MatchString(tag) {
		return errBadTag
	}
	err := os.Remove(s.blockPath(tag))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

// Purge deletes records not seen for the given number of days. An app whose
// record was purged is told its key is unknown and attests a new one.
func (s *Store) Purge(now time.Time, idleDays int) (int, error) {
	if err := s.Flush(); err != nil {
		return 0, err
	}
	cutoff := now.UTC().AddDate(0, 0, -idleDays).Format(DayFormat)
	s.mu.Lock()
	defer s.mu.Unlock()
	entries, err := os.ReadDir(filepath.Join(s.dir, "installs"))
	if err != nil {
		return 0, err
	}
	removed := 0
	for _, e := range entries {
		if !installFilePattern.MatchString(e.Name()) {
			continue
		}
		p := filepath.Join(s.dir, "installs", e.Name())
		data, err := os.ReadFile(p)
		if err != nil {
			return removed, err
		}
		var in Install
		if json.Unmarshal(data, &in) != nil || in.LastSeenDay < cutoff {
			if err := os.Remove(p); err != nil {
				return removed, err
			}
			removed++
		}
	}
	return removed, nil
}

// Count returns how many installs are on record, for the owner's CLI.
func (s *Store) Count() (int, error) {
	entries, err := os.ReadDir(filepath.Join(s.dir, "installs"))
	if err != nil {
		return 0, err
	}
	n := 0
	for _, e := range entries {
		if installFilePattern.MatchString(e.Name()) {
			n++
		}
	}
	return n, nil
}

// PruneHourLog drops JSON lines whose "hour" field is older than the given
// number of days. It keeps the abuse log from becoming a long-term record.
func PruneHourLog(path string, now time.Time, days int) (int, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return 0, nil
	} else if err != nil {
		return 0, err
	}
	cutoff := now.UTC().AddDate(0, 0, -days).Format("2006-01-02T15")
	var kept []byte
	dropped := 0
	for _, line := range strings.Split(strings.TrimRight(string(data), "\n"), "\n") {
		if line == "" {
			continue
		}
		var entry struct {
			Hour string `json:"hour"`
		}
		if json.Unmarshal([]byte(line), &entry) != nil || entry.Hour < cutoff {
			dropped++
			continue
		}
		kept = append(kept, line+"\n"...)
	}
	if dropped == 0 {
		return 0, nil
	}
	return dropped, writeAtomic(path, kept)
}

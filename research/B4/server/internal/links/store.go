package links

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Lifetime is how long a link works. The daily sweep deletes it after that.
const Lifetime = 30 * 24 * time.Hour

var (
	ErrNotFound  = errors.New("links: not found")
	ErrExpired   = errors.New("links: expired")
	ErrTooLarge  = errors.New("links: packet too large")
	ErrBadPacket = errors.New("links: not a Spoken Margins packet")
	// ErrFull means the links directory is at its size cap.
	ErrFull = errors.New("links: storage full")
)

// zipMagic starts every .spokenmargins packet (a ZIP archive). Checking it
// keeps the endpoint from becoming a general file drop.
var zipMagic = []byte("PK\x03\x04")

// idBytes is 128 random bits, written as 22 base64url characters.
const idBytes = 16

// NewID makes an unguessable link id.
func NewID() (string, error) {
	b := make([]byte, idBytes)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// ValidID reports whether id has the shape NewID makes, so nothing else is
// ever used as a file name.
func ValidID(id string) bool {
	if len(id) != base64.RawURLEncoding.EncodedLen(idBytes) {
		return false
	}
	for _, c := range id {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}

// Link is one stored link's record. The packet is a separate file.
type Link struct {
	CreatedAt time.Time `json:"createdAt"`
	Preview   Preview   `json:"preview"`
}

func (l Link) ExpiresAt() time.Time { return l.CreatedAt.Add(Lifetime) }

// Store keeps each link as two files, named by id, under one directory only
// the service can read:
//
//	<id>.json    the record: when it was made and the preview
//	<id>.packet  the packet, byte for byte as uploaded
//
// The record is written last, so a link exists only once both files do.
type Store struct {
	dir string
	// MaxBytes caps the directory's total size, so uploads can't fill the
	// box's disk. Zero means no cap.
	MaxBytes int64
}

func OpenStore(dir string) (*Store, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	return &Store{dir: dir}, nil
}

func (s *Store) recordPath(id string) string { return filepath.Join(s.dir, id+".json") }
func (s *Store) packetPath(id string) string { return filepath.Join(s.dir, id+".packet") }

// size is the directory's total size in bytes.
func (s *Store) size() (int64, error) {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return 0, err
	}
	var n int64
	for _, e := range entries {
		if info, err := e.Info(); err == nil {
			n += info.Size()
		}
	}
	return n, nil
}

// Create stores a packet read from r with its preview and returns the new
// link's id. It streams the packet to disk, so a 20 MB upload never sits in
// memory, and rejects one over MaxPacketBytes or not starting like a ZIP.
func (s *Store) Create(r io.Reader, p Preview, now time.Time) (string, error) {
	id, err := NewID()
	if err != nil {
		return "", err
	}
	tmp, err := os.CreateTemp(s.dir, ".tmp-*")
	if err != nil {
		return "", err
	}
	defer os.Remove(tmp.Name())
	n, err := io.Copy(tmp, io.LimitReader(r, MaxPacketBytes+1))
	if err != nil {
		tmp.Close()
		return "", err
	}
	if n > MaxPacketBytes {
		tmp.Close()
		return "", ErrTooLarge
	}
	head := make([]byte, len(zipMagic))
	if _, err := tmp.ReadAt(head, 0); err != nil || !bytes.Equal(head, zipMagic) {
		tmp.Close()
		return "", ErrBadPacket
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return "", err
	}
	if err := tmp.Close(); err != nil {
		return "", err
	}
	if s.MaxBytes > 0 {
		// The temporary file is counted too, so this is the size with the
		// new packet in place.
		if total, err := s.size(); err != nil {
			return "", err
		} else if total > s.MaxBytes {
			return "", ErrFull
		}
	}
	if err := os.Rename(tmp.Name(), s.packetPath(id)); err != nil {
		return "", err
	}
	record, err := json.Marshal(Link{CreatedAt: now.UTC(), Preview: p})
	if err == nil {
		err = writeAtomic(s.recordPath(id), append(record, '\n'))
	}
	if err != nil {
		os.Remove(s.packetPath(id))
		return "", err
	}
	return id, nil
}

// Get returns a link's record, or ErrExpired once its 30 days are up (until
// the sweep deletes it, after which it is ErrNotFound).
func (s *Store) Get(id string, now time.Time) (Link, error) {
	var l Link
	if !ValidID(id) {
		return l, ErrNotFound
	}
	data, err := os.ReadFile(s.recordPath(id))
	if errors.Is(err, os.ErrNotExist) {
		return l, ErrNotFound
	} else if err != nil {
		return l, err
	}
	if err := json.Unmarshal(data, &l); err != nil {
		return l, err
	}
	if !now.Before(l.ExpiresAt()) {
		return l, ErrExpired
	}
	return l, nil
}

// OpenPacket opens a live link's packet for reading.
func (s *Store) OpenPacket(id string, now time.Time) (*os.File, error) {
	if _, err := s.Get(id, now); err != nil {
		return nil, err
	}
	f, err := os.Open(s.packetPath(id))
	if errors.Is(err, os.ErrNotExist) {
		return nil, ErrNotFound
	}
	return f, err
}

// Takedown deletes a link at once. It reports whether there was one.
func (s *Store) Takedown(id string) (bool, error) {
	if !ValidID(id) {
		return false, errors.New("links: a link id is the 22 characters after /l/")
	}
	errRecord := os.Remove(s.recordPath(id))
	errPacket := os.Remove(s.packetPath(id))
	for _, err := range []error{errRecord, errPacket} {
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return false, err
		}
	}
	return errRecord == nil || errPacket == nil, nil
}

// Sweep deletes every link whose 30 days are up, any record it can't read,
// any packet left without a record, and stray temporary files. Packets and
// temporary files under an hour old may be an upload in progress, so they
// stay. It returns how many files it deleted.
func (s *Store) Sweep(now time.Time) (int, error) {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return 0, err
	}
	n := 0
	remove := func(name string) {
		if os.Remove(filepath.Join(s.dir, name)) == nil {
			n++
		}
	}
	old := func(e os.DirEntry) bool {
		info, err := e.Info()
		return err == nil && now.Sub(info.ModTime()) >= time.Hour
	}
	for _, e := range entries {
		name := e.Name()
		if id, ok := strings.CutSuffix(name, ".json"); ok && ValidID(id) {
			if _, err := s.Get(id, now); err == nil || errors.Is(err, ErrNotFound) {
				continue
			}
			// Expired, or a record that can't be read: the link is gone.
			remove(name)
			remove(id + ".packet")
			continue
		}
		if id, ok := strings.CutSuffix(name, ".packet"); ok && ValidID(id) {
			if _, err := os.Stat(s.recordPath(id)); errors.Is(err, os.ErrNotExist) && old(e) {
				remove(name)
			}
			continue
		}
		if old(e) {
			remove(name)
		}
	}
	return n, nil
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

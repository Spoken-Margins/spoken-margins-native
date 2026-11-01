// Package links stores share packets without interpreting or changing their bytes.
package links

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const (
	MaxPacketBytes  = 20 << 20
	MaxPreviewBytes = 16 << 10
	Lifetime        = 30 * 24 * time.Hour
)

var (
	ErrNotFound = errors.New("links: not found")
	ErrGone     = errors.New("links: gone")
	ErrTooLarge = errors.New("links: too large")
	ErrUnsealed = errors.New("links: not a sealed part")
)

// previewFile holds the sealed preview. Before #805 reached the server it was "preview.json", a
// readable preview; no shipped build ever uploaded one, but takedown and the sweep still delete
// that name so no readable copy outlives its link.
const previewFile = "preview"

var contentFiles = []string{"packet", previewFile, "preview.json"}

// Only expiry metadata survives deletion, so previously issued links still
// answer 410 after a sweep or takedown. No content or client address survives.
type Store struct {
	dir string
	mu  sync.RWMutex
}
type metadata struct {
	ExpiresAt time.Time `json:"expiresAt"`
}

func OpenStore(dir string) (*Store, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	return &Store{dir: dir}, nil
}

func ValidID(id string) bool {
	if len(id) != 32 {
		return false
	}
	for _, c := range id {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// Put publishes a complete directory atomically. A failed upload leaves no link.
// Both parts must be sealed (#805); their bytes are stored as they came.
func (s *Store) Put(packet []byte, preview []byte, now time.Time) (string, time.Time, error) {
	if len(packet) == 0 {
		return "", time.Time{}, errors.New("links: empty packet")
	}
	if len(packet) > MaxPacketBytes || len(preview) > MaxPreviewBytes {
		return "", time.Time{}, ErrTooLarge
	}
	if !Sealed(preview, PartPreview) || !Sealed(packet, PartPacket) {
		return "", time.Time{}, ErrUnsealed
	}
	idBytes := make([]byte, 16)
	if _, err := rand.Read(idBytes); err != nil {
		return "", time.Time{}, err
	}
	id := hex.EncodeToString(idBytes)
	expires := now.UTC().Add(Lifetime)
	dir, err := os.MkdirTemp(s.dir, ".upload-")
	if err != nil {
		return "", time.Time{}, err
	}
	defer os.RemoveAll(dir)
	meta, _ := json.Marshal(metadata{ExpiresAt: expires})
	for name, data := range map[string][]byte{"meta.json": meta, "packet": packet, previewFile: preview} {
		if err := os.WriteFile(filepath.Join(dir, name), data, 0o600); err != nil {
			return "", time.Time{}, err
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	// Do not overwrite an existing id, even in the extraordinarily unlikely
	// event of a random collision.
	if _, err := os.Stat(filepath.Join(s.dir, id)); !errors.Is(err, os.ErrNotExist) {
		return "", time.Time{}, errors.New("links: id collision")
	}
	if err := os.Rename(dir, filepath.Join(s.dir, id)); err != nil {
		return "", time.Time{}, err
	}
	return id, expires, nil
}

func (s *Store) live(id string, now time.Time) error {
	if !ValidID(id) {
		return ErrNotFound
	}
	data, err := os.ReadFile(filepath.Join(s.dir, id, "meta.json"))
	if errors.Is(err, os.ErrNotExist) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	var meta metadata
	if err := json.Unmarshal(data, &meta); err != nil {
		return err
	}
	if !now.Before(meta.ExpiresAt) {
		return ErrGone
	}
	return nil
}

// Live answers nil while the link can be opened, ErrNotFound or ErrGone otherwise.
func (s *Store) Live(id string, now time.Time) error {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if err := s.live(id, now); err != nil {
		return err
	}
	if _, err := os.Stat(filepath.Join(s.dir, id, previewFile)); errors.Is(err, os.ErrNotExist) {
		return ErrGone
	} else if err != nil {
		return err
	}
	return nil
}

// Preview returns the sealed preview bytes unchanged. Only the browser, with the key, can open them.
func (s *Store) Preview(id string, now time.Time) ([]byte, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if err := s.live(id, now); err != nil {
		return nil, err
	}
	data, err := os.ReadFile(filepath.Join(s.dir, id, previewFile))
	if errors.Is(err, os.ErrNotExist) {
		return nil, ErrGone
	}
	return data, err
}

// Packet opens a real file so serving a download does not buffer another 20 MB.
func (s *Store) Packet(id string, now time.Time) (*os.File, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if err := s.live(id, now); err != nil {
		return nil, err
	}
	f, err := os.Open(filepath.Join(s.dir, id, "packet"))
	if errors.Is(err, os.ErrNotExist) {
		return nil, ErrGone
	}
	return f, err
}

func (s *Store) deleteContent(id string) error {
	for _, name := range contentFiles {
		if err := os.Remove(filepath.Join(s.dir, id, name)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	return nil
}

// Sweep uses the stored deadline, not access or modification times. Tombstones
// remain so an expired id cannot turn into a misleading 404 after the sweep.
func (s *Store) Sweep(now time.Time) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return 0, err
	}
	n := 0
	for _, e := range entries {
		if !ValidID(e.Name()) {
			// An interrupted upload may leave a temporary directory. Avoid active writes.
			if info, err := e.Info(); err == nil && now.Sub(info.ModTime()) >= time.Hour {
				if err := os.RemoveAll(filepath.Join(s.dir, e.Name())); err != nil {
					return n, err
				}
			}
			continue
		}
		if err := s.live(e.Name(), now); errors.Is(err, ErrGone) {
			stored := false
			for _, name := range contentFiles {
				if _, err := os.Stat(filepath.Join(s.dir, e.Name(), name)); err == nil {
					stored = true
				}
			}
			if err := s.deleteContent(e.Name()); err != nil {
				return n, err
			}
			if stored {
				n++
			}
		} else if err != nil {
			return n, err
		}
	}
	return n, nil
}

// Takedown works from a separate CLI process too: publish the tombstone before
// deleting content, so every subsequent request is refused immediately.
func (s *Store) Takedown(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.takedownLocked(id)
}

// Disable stops a link being served and keeps its content, for when a hold could not be made: the
// link goes dark at once and the ciphertext stays for the hold to be retried. The daily sweep still
// deletes the content when the link would have expired anyway.
func (s *Store) Disable(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.tombstoneLocked(id)
}

func (s *Store) takedownLocked(id string) error {
	if err := s.tombstoneLocked(id); err != nil {
		return err
	}
	return s.deleteContent(id)
}

// tombstoneLocked publishes the expired metadata, so every later request is refused.
func (s *Store) tombstoneLocked(id string) error {
	if !ValidID(id) {
		return ErrNotFound
	}
	dir := filepath.Join(s.dir, id)
	if _, err := os.Stat(dir); errors.Is(err, os.ErrNotExist) {
		return ErrNotFound
	} else if err != nil {
		return err
	}
	f, err := os.CreateTemp(dir, ".meta-")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	data, _ := json.Marshal(metadata{ExpiresAt: time.Unix(0, 0).UTC()})
	_, err = f.Write(data)
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(f.Name(), filepath.Join(dir, "meta.json"))
}

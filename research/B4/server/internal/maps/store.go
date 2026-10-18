package maps

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// TranscriptMaxAge is how long the sweep lets a transcript wait in memory.
// The sweep runs hourly, so none outlives about three hours even if the
// worker is stuck; normally the worker drops it within a minute of the
// upload. A restart drops them all, since they were never written anywhere.
const TranscriptMaxAge = 2 * time.Hour

var ErrNotFound = errors.New("maps: not found")

// Store keeps maps and withdrawn keys as one small file each, named by
// episode key, under one directory only the service can read. Waiting
// transcripts live in memory only (#1730): nothing of a transcript is ever
// written to disk, so there is no file to retain, sweep or delete.
//
//	maps/<key>.json         served
//	withdrawn/<key>         taken down by the owner; no new map is made
type Store struct {
	dir string

	mu    sync.Mutex
	queue map[string]waiting
	order []string // keys in arrival order, oldest first
}

func OpenStore(dir string) (*Store, error) {
	for _, sub := range []string{"maps", "withdrawn"} {
		if err := os.MkdirAll(filepath.Join(dir, sub), 0o700); err != nil {
			return nil, err
		}
	}
	// An earlier version queued transcripts as files. None may outlive the
	// upgrade, and the worker could not use them now.
	if err := os.RemoveAll(filepath.Join(dir, "transcripts")); err != nil {
		return nil, err
	}
	return &Store{dir: dir, queue: map[string]waiting{}}, nil
}

func (s *Store) mapPath(key string) string       { return filepath.Join(s.dir, "maps", key+".json") }
func (s *Store) withdrawnPath(key string) string { return filepath.Join(s.dir, "withdrawn", key) }

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

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func (s *Store) HasMap(key string) bool    { return ValidKey(key) && exists(s.mapPath(key)) }
func (s *Store) Withdrawn(key string) bool { return ValidKey(key) && exists(s.withdrawnPath(key)) }

// MapBytes returns a stored map exactly as written.
func (s *Store) MapBytes(key string) ([]byte, error) {
	if !ValidKey(key) {
		return nil, ErrNotFound
	}
	data, err := os.ReadFile(s.mapPath(key))
	if errors.Is(err, os.ErrNotExist) {
		return nil, ErrNotFound
	}
	return data, err
}

// PutMap stores a map unless its key was withdrawn meanwhile.
func (s *Store) PutMap(m Map) error {
	if !ValidKey(m.EpisodeKey) {
		return ErrNotFound
	}
	if s.Withdrawn(m.EpisodeKey) {
		return nil
	}
	data, err := json.Marshal(m)
	if err != nil {
		return err
	}
	if err := writeAtomic(s.mapPath(m.EpisodeKey), append(data, '\n')); err != nil {
		return err
	}
	// A takedown that ran between the check above and the write wins.
	if s.Withdrawn(m.EpisodeKey) {
		return os.Remove(s.mapPath(m.EpisodeKey))
	}
	return nil
}

// Takedown deletes a map at once and withdraws its key, so a phone that
// uploads the same episode again doesn't bring it back. Deleting the
// withdrawn/<key> file allows a new map.
func (s *Store) Takedown(key string) (bool, error) {
	if !ValidKey(key) {
		return false, errors.New("maps: an episode key is 64 lowercase hex characters")
	}
	if err := writeAtomic(s.withdrawnPath(key), nil); err != nil {
		return false, err
	}
	s.DeleteTranscript(key)
	err := os.Remove(s.mapPath(key))
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	return err == nil, err
}

// waiting is a transcript in memory with the time it arrived, which the
// sweep reads so a test can drive it with a fake clock.
type waiting struct {
	ReceivedAt time.Time
	Transcript Transcript
}

// HasTranscript reports whether a transcript for key is waiting.
func (s *Store) HasTranscript(key string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, ok := s.queue[key]
	return ok
}

// PutTranscript queues a transcript for the worker, in memory only. One
// already waiting for the episode is kept, and the new one is dropped.
func (s *Store) PutTranscript(t Transcript, now time.Time) error {
	if !ValidKey(t.EpisodeKey) {
		return ErrNotFound
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.queue[t.EpisodeKey]; ok {
		return nil
	}
	s.queue[t.EpisodeKey] = waiting{ReceivedAt: now.UTC(), Transcript: t}
	s.order = append(s.order, t.EpisodeKey)
	return nil
}

// DeleteTranscript drops a waiting transcript. Dropping one that isn't
// waiting is not an error.
func (s *Store) DeleteTranscript(key string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.queue, key)
	for i, k := range s.order {
		if k == key {
			s.order = append(s.order[:i], s.order[i+1:]...)
			break
		}
	}
	return nil
}

// CountTranscripts is how many transcripts are waiting.
func (s *Store) CountTranscripts() (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.queue), nil
}

// WaitingKeys lists the waiting transcripts' keys, oldest first. It copies
// no transcript, so the worker holds at most the one it is mapping.
func (s *Store) WaitingKeys() ([]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.order...), nil
}

// ReadTranscript returns one waiting transcript, or ErrNotFound.
func (s *Store) ReadTranscript(key string) (Transcript, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	w, ok := s.queue[key]
	if !ok {
		return Transcript{}, ErrNotFound
	}
	return w.Transcript, nil
}

// Sweep drops every waiting transcript older than maxAge and returns how
// many it dropped.
func (s *Store) Sweep(now time.Time, maxAge time.Duration) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	kept := s.order[:0]
	n := 0
	for _, key := range s.order {
		if now.Sub(s.queue[key].ReceivedAt) < maxAge {
			kept = append(kept, key)
			continue
		}
		delete(s.queue, key)
		n++
	}
	s.order = kept
	return n, nil
}

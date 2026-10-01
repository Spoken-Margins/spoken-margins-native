package maps

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// TranscriptMaxAge is how long the sweep lets a transcript wait. The sweep
// runs hourly, so no transcript outlives 24 hours even if the worker is
// stuck; normally the worker deletes it within a minute of the upload.
const TranscriptMaxAge = 23 * time.Hour

var ErrNotFound = errors.New("maps: not found")

// Store keeps maps, waiting transcripts and withdrawn keys as one small file
// each, named by episode key, under one directory only the service can read.
//
//	maps/<key>.json         served
//	transcripts/<key>.json  waiting for the worker, never served
//	withdrawn/<key>         taken down by the owner; no new map is made
type Store struct{ dir string }

func OpenStore(dir string) (*Store, error) {
	for _, sub := range []string{"maps", "transcripts", "withdrawn"} {
		if err := os.MkdirAll(filepath.Join(dir, sub), 0o700); err != nil {
			return nil, err
		}
	}
	return &Store{dir: dir}, nil
}

func (s *Store) mapPath(key string) string { return filepath.Join(s.dir, "maps", key+".json") }
func (s *Store) transcriptPath(key string) string {
	return filepath.Join(s.dir, "transcripts", key+".json")
}
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
	return writeAtomic(s.mapPath(m.EpisodeKey), append(data, '\n'))
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
	os.Remove(s.transcriptPath(key))
	err := os.Remove(s.mapPath(key))
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	return err == nil, err
}

// waiting is a transcript on disk with the time it arrived, which the sweep
// reads instead of file times so a test can drive it with a fake clock.
type waiting struct {
	ReceivedAt time.Time  `json:"receivedAt"`
	Transcript Transcript `json:"transcript"`
}

// HasTranscript reports whether a transcript for key is waiting.
func (s *Store) HasTranscript(key string) bool {
	return ValidKey(key) && exists(s.transcriptPath(key))
}

// PutTranscript queues a transcript for the worker.
func (s *Store) PutTranscript(t Transcript, now time.Time) error {
	data, err := json.Marshal(waiting{ReceivedAt: now.UTC(), Transcript: t})
	if err != nil {
		return err
	}
	return writeAtomic(s.transcriptPath(t.EpisodeKey), data)
}

func (s *Store) DeleteTranscript(key string) error {
	err := os.Remove(s.transcriptPath(key))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

func (s *Store) transcriptKeys() ([]string, error) {
	entries, err := os.ReadDir(filepath.Join(s.dir, "transcripts"))
	if err != nil {
		return nil, err
	}
	var keys []string
	for _, e := range entries {
		key, ok := strings.CutSuffix(e.Name(), ".json")
		if ok && ValidKey(key) {
			keys = append(keys, key)
		}
	}
	return keys, nil
}

// CountTranscripts is how many transcripts are waiting.
func (s *Store) CountTranscripts() (int, error) {
	keys, err := s.transcriptKeys()
	return len(keys), err
}

func (s *Store) readWaiting(key string) (waiting, error) {
	var w waiting
	data, err := os.ReadFile(s.transcriptPath(key))
	if err != nil {
		return w, err
	}
	return w, json.Unmarshal(data, &w)
}

// Waiting returns the waiting transcripts, oldest first. One that can't be
// read is deleted: it can never be mapped, and must not linger.
func (s *Store) Waiting() ([]Transcript, error) {
	keys, err := s.transcriptKeys()
	if err != nil {
		return nil, err
	}
	var all []waiting
	for _, key := range keys {
		w, err := s.readWaiting(key)
		if err != nil {
			s.DeleteTranscript(key)
			continue
		}
		all = append(all, w)
	}
	sort.Slice(all, func(i, j int) bool { return all[i].ReceivedAt.Before(all[j].ReceivedAt) })
	out := make([]Transcript, len(all))
	for i, w := range all {
		out[i] = w.Transcript
	}
	return out, nil
}

// Sweep deletes every transcript older than maxAge, and any it can't read,
// and returns how many it deleted. Stray temporary files go too.
func (s *Store) Sweep(now time.Time, maxAge time.Duration) (int, error) {
	dir := filepath.Join(s.dir, "transcripts")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0, err
	}
	n := 0
	for _, e := range entries {
		key, ok := strings.CutSuffix(e.Name(), ".json")
		if !ok || !ValidKey(key) {
			// A temporary file an interrupted write left behind. A fresh one
			// may be a write in progress, so only old ones go.
			if info, err := e.Info(); err == nil && now.Sub(info.ModTime()) >= time.Hour &&
				os.Remove(filepath.Join(dir, e.Name())) == nil {
				n++
			}
			continue
		}
		w, err := s.readWaiting(key)
		if err == nil && now.Sub(w.ReceivedAt) < maxAge {
			continue
		}
		if s.DeleteTranscript(key) == nil {
			n++
		}
	}
	return n, nil
}

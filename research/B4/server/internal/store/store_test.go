package store

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRegisterAdvanceBlockPurge(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	day := time.Date(2026, 9, 28, 15, 4, 5, 0, time.UTC)
	key := []byte("key-one-32-bytes-long-0123456789")
	in := Install{PublicKey: []byte{4, 1}, Environment: "production", CreatedDay: day.Format(DayFormat), LastSeenDay: day.Format(DayFormat)}
	if err := s.Register(key, in); err != nil {
		t.Fatal(err)
	}
	if err := s.Register(key, in); !errors.Is(err, ErrExists) {
		t.Fatalf("second register: %v", err)
	}
	if err := s.Advance(key, 1, day); err != nil {
		t.Fatal(err)
	}
	if err := s.Advance(key, 1, day); !errors.Is(err, ErrStaleCounter) {
		t.Fatalf("stale counter accepted: %v", err)
	}

	// The record holds nothing but what the struct declares.
	raw, _ := os.ReadFile(s.path(key))
	for _, forbidden := range []string{"ip", "name", "email", "model", "follow"} {
		if strings.Contains(strings.ToLower(string(raw)), `"`+forbidden) {
			t.Fatalf("record contains %q: %s", forbidden, raw)
		}
	}

	if s.IsBlocked(key) {
		t.Fatal("blocked before blocking")
	}
	if err := s.Block(Tag(key)); err != nil {
		t.Fatal(err)
	}
	if !s.IsBlocked(key) {
		t.Fatal("block not applied")
	}
	if err := s.Block("../../etc/passwd"); err == nil {
		t.Fatal("path-like tag accepted")
	}

	other := []byte("key-two-32-bytes-long-0123456789")
	old := day.AddDate(0, 0, -100).Format(DayFormat)
	_ = s.Register(other, Install{CreatedDay: old, LastSeenDay: old})
	n, err := s.Purge(day, 90)
	if err != nil || n != 1 {
		t.Fatalf("purge removed %d, %v", n, err)
	}
	if _, err := s.Get(other); !errors.Is(err, ErrNotFound) {
		t.Fatal("idle install survived purge")
	}
	if _, err := s.Get(key); err != nil {
		t.Fatal("active install purged")
	}

	// A block outlives the record, so an expired record doesn't lift it.
	os.Remove(s.path(key))
	if !s.IsBlocked(key) {
		t.Fatal("block lost with record")
	}
	if err := s.Unblock(Tag(key)); err != nil || s.IsBlocked(key) {
		t.Fatalf("unblock: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "blocked")); err != nil {
		t.Fatal(err)
	}
}

func TestPruneHourLog(t *testing.T) {
	p := filepath.Join(t.TempDir(), "abuse.log")
	os.WriteFile(p, []byte(`{"hour":"2026-07-01T10","tag":"aaaaaaaaaaaaaaaa","reason":"rate_limited"}
{"hour":"2026-09-27T10","tag":"bbbbbbbbbbbbbbbb","reason":"rate_limited"}
`), 0o600)
	n, err := PruneHourLog(p, time.Date(2026, 9, 28, 0, 0, 0, 0, time.UTC), 30)
	if err != nil || n != 1 {
		t.Fatalf("pruned %d, %v", n, err)
	}
	data, _ := os.ReadFile(p)
	if strings.Contains(string(data), "aaaa") || !strings.Contains(string(data), "bbbb") {
		t.Fatalf("after prune: %s", data)
	}
}

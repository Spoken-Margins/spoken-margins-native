package reports

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"spokenmargins.dev/bridge/internal/reportrules"
)

const day = 24 * time.Hour

var t0 = time.Date(2026, 11, 1, 12, 0, 0, 0, time.UTC)

func open(t *testing.T) (*Store, string) {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "reports")
	s, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	return s, dir
}

func TestHandleIsKeyedPerProcessAndKindSeparated(t *testing.T) {
	s, dir := open(t)
	h := s.Handle("net", "203.0.113.0")
	if len(h) != 64 || strings.Contains(h, "203.0.113") {
		t.Fatal("handle looks like the address")
	}
	if s.Handle("net", "203.0.113.0") != h || s.Handle("email", "203.0.113.0") == h {
		t.Fatal("handle is not stable inside a run, or kinds collide")
	}
	again, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if again.Handle("net", "203.0.113.0") == h {
		t.Fatal("the key outlived the process: a handle could be recomputed from a disk copy")
	}
	// Nothing about a reporter is on disk, not even a key.
	s.Note(h, t0, 7*day)
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		data, _ := os.ReadFile(filepath.Join(dir, e.Name()))
		if strings.Contains(string(data), h) {
			t.Fatalf("%s holds the handle", e.Name())
		}
		if e.Name() == "reporter.key" {
			t.Fatal("a handle key was written")
		}
	}
}

func TestNoteReturnsOnlyThisHandlesReportsInsideTheWindow(t *testing.T) {
	s, _ := open(t)
	me, you := s.Handle("net", "a"), s.Handle("net", "b")
	if got := s.Note(me, t0.Add(-8*day), 7*day); len(got) != 0 {
		t.Fatalf("first: %v", got)
	}
	s.Note(me, t0.Add(-7*day), 7*day) // 8 days after the first would drop it; this one is the edge
	s.Note(you, t0.Add(-day), 7*day)
	got := s.Note(me, t0, 7*day)
	if len(got) != 1 || !got[0].Equal(t0.Add(-7*day)) {
		t.Fatalf("the edge counts, 8 days does not, and others never do: %v", got)
	}
}

func TestNoteIsAtomicUnderConcurrentReports(t *testing.T) {
	s, _ := open(t)
	h := s.Handle("net", "a")
	var wg sync.WaitGroup
	var mu sync.Mutex
	empty := 0
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if len(s.Note(h, t0, 7*day)) == 0 {
				mu.Lock()
				empty++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	if empty != 1 {
		t.Fatalf("%d of 20 simultaneous reports saw no earlier report; exactly one should", empty)
	}
}

func TestAddReasonOnceAndOnlyForTheRightLink(t *testing.T) {
	s, _ := open(t)
	s.Add(Record{Ref: "R1", LinkID: "l1", Category: reportrules.Other, At: t0})
	for _, c := range []struct {
		ref, link, reason string
		want              error
	}{
		{"R1", "l1", "  ", ErrReasonMissing},
		{"R1", "l1", strings.Repeat("x", MaxReasonBytes+1), ErrReasonTooLong},
		{"R1", "l2", "x", ErrNotFound},
		{"R9", "l1", "x", ErrNotFound},
		{"R1", "l1", "x", nil},
		{"R1", "l1", "y", ErrReasonGiven},
	} {
		if err := s.AddReason(c.ref, c.link, c.reason); err != c.want {
			t.Fatalf("%+v: %v", c, err)
		}
	}
	recs, _ := s.load()
	if len(recs) != 1 || recs[0].Reason != "x" {
		t.Fatalf("%+v", recs)
	}
}

func TestSweepDeletesRecordsAfterNinetyDaysAndForgetsWindows(t *testing.T) {
	s, _ := open(t)
	for i, age := range []time.Duration{day, 90 * day, 90*day + time.Second} {
		s.Add(Record{Ref: string(rune('A' + i)), LinkID: "l", Category: reportrules.Other, At: t0.Add(-age)})
	}
	h := s.Handle("net", "a")
	s.Note(h, t0.Add(-8*day), 7*day)
	n, err := s.Sweep(t0, 7*day, 90*day)
	if err != nil || n != 1 {
		t.Fatalf("deleted %d %v", n, err)
	}
	if recs, _ := s.load(); len(recs) != 2 {
		t.Fatalf("%+v", recs)
	}
	if got := s.Note(h, t0, 8*day+time.Hour); len(got) != 0 {
		t.Fatalf("a window older than 7 days survived the sweep: %v", got)
	}
	if n, err := s.Sweep(t0, 7*day, 90*day); err != nil || n != 0 {
		t.Fatalf("second sweep %d %v", n, err)
	}
}

func TestAKeyPastedIntoAReasonIsNotStoredExceptForAbuseMaterial(t *testing.T) {
	const link = "https://spokenmargins.com/l/0123456789abcdef0123456789abcdef#SECRETKEY"
	for _, c := range reportrules.Categories() {
		s, dir := open(t)
		s.Add(Record{Ref: "R1", LinkID: "l1", Category: c, At: t0, Reason: "this " + link + " is bad"})
		s.Add(Record{Ref: "R2", LinkID: "l2", Category: c, At: t0})
		if err := s.AddReason("R2", "l2", "see "+link); err != nil {
			t.Fatal(err)
		}
		data, _ := os.ReadFile(filepath.Join(dir, recordsFile))
		has := strings.Contains(string(data), "SECRETKEY")
		if has != c.CarriesKey() {
			t.Fatalf("%s: key stored = %v", c, has)
		}
		if !c.CarriesKey() && !strings.Contains(string(data), "this [link removed] is bad") {
			t.Fatalf("%s: the rest of the reason was lost: %s", c, data)
		}
	}
}

func TestNewRefIsTwelveUnambiguousCharacters(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 200; i++ {
		ref, err := NewRef()
		if err != nil || len(ref) != 12 || strings.ContainsAny(ref, "01OIL") || strings.ToUpper(ref) != ref {
			t.Fatalf("%q %v", ref, err)
		}
		seen[ref] = true
	}
	if len(seen) != 200 {
		t.Fatal("refs repeat")
	}
}

func TestUnreadableRecordsRefuseToOpen(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "reports")
	if _, err := Open(dir); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(dir, recordsFile), []byte("{"), 0o600)
	if _, err := Open(dir); err == nil {
		t.Fatal("opened over a damaged record file")
	}
}

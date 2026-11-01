package reports

import (
	"os"
	"path/filepath"
	"strings"
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

func TestHandleIsKeyedStableAcrossRestartsAndKindSeparated(t *testing.T) {
	s, dir := open(t)
	h := s.Handle("net", "203.0.113.0")
	if strings.Contains(h, "203") && strings.Contains(h, "113") && len(h) < 64 {
		t.Fatal("handle looks like the address")
	}
	again, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if again.Handle("net", "203.0.113.0") != h {
		t.Fatal("same phone, different handle after a restart")
	}
	if s.Handle("email", "203.0.113.0") == h {
		t.Fatal("kinds collide")
	}
	other, _ := open(t)
	if other.Handle("net", "203.0.113.0") == h {
		t.Fatal("two servers share a handle key")
	}
	if info, err := os.Stat(filepath.Join(dir, keyFile)); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("key file mode %v %v", info, err)
	}
}

func TestPriorCountsOnlyThisHandleInsideTheWindow(t *testing.T) {
	s, _ := open(t)
	me, you := s.Handle("net", "a"), s.Handle("net", "b")
	for _, r := range []Record{
		{Ref: "R1", LinkID: "l1", Category: reportrules.Other, At: t0.Add(-8 * day), Reporter: me},
		{Ref: "R2", LinkID: "l2", Category: reportrules.Other, At: t0.Add(-7 * day), Reporter: me},
		{Ref: "R3", LinkID: "l3", Category: reportrules.Other, At: t0.Add(-day), Reporter: you},
		{Ref: "R4", LinkID: "l4", Category: reportrules.Other, At: t0.Add(-day)},
	} {
		if err := s.Add(r); err != nil {
			t.Fatal(err)
		}
	}
	got, err := s.Prior(me, t0, 7*day)
	if err != nil || len(got) != 1 || !got[0].Equal(t0.Add(-7*day)) {
		t.Fatalf("the edge counts, 8 days does not, and others never do: %v %v", got, err)
	}
	if got, _ := s.Prior("", t0, 7*day); len(got) != 0 {
		t.Fatal("an empty handle matched records with none")
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

func TestSweepClearsHandlesAfterSevenDaysAndRecordsAfterNinety(t *testing.T) {
	s, dir := open(t)
	for i, age := range []time.Duration{day, 8 * day, 91 * day} {
		s.Add(Record{Ref: string(rune('A' + i)), LinkID: "l", Category: reportrules.Other, At: t0.Add(-age), Reporter: "h"})
	}
	n, err := s.Sweep(t0, 7*day, 90*day)
	if err != nil || n != 1 {
		t.Fatalf("deleted %d %v", n, err)
	}
	recs, _ := s.load()
	if len(recs) != 2 || recs[0].Reporter != "h" || recs[1].Reporter != "" {
		t.Fatalf("%+v", recs)
	}
	if n, err := s.Sweep(t0, 7*day, 90*day); err != nil || n != 0 {
		t.Fatalf("second sweep %d %v", n, err)
	}
	if data, _ := os.ReadFile(filepath.Join(dir, recordsFile)); strings.Count(string(data), `"reporter"`) != 1 {
		t.Fatalf("a cleared handle is still on disk: %s", data)
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

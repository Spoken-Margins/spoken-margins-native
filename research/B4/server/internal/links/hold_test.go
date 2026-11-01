package links

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var holdNow = time.Date(2026, 11, 1, 12, 0, 0, 0, time.UTC)

// putLink stores the shared vector's sealed parts and returns the store, the link id and the stored bytes.
func putLink(t *testing.T) (*Store, string, []byte, []byte) {
	t.Helper()
	preview, packet, _, _ := loadVector(t)
	st, err := OpenStore(filepath.Join(t.TempDir(), "links"))
	if err != nil {
		t.Fatal(err)
	}
	id, _, err := st.Put(packet, preview, holdNow)
	if err != nil {
		t.Fatal(err)
	}
	return st, id, packet, preview
}

func heldFile(st *Store, id, name string) string { return filepath.Join(st.heldDir(), id, name) }

func TestHeldLinkSurvivesTheThirtyDaySweepIsNeverServedAndIsDeletedAtOneYear(t *testing.T) {
	st, id, packet, preview := putLink(t)
	fullLink := []byte("https://share.example/l/" + id + "#k=KEYFRAGMENT")
	if err := st.Hold(id, "NCMEC-1234", fullLink, holdNow); err != nil {
		t.Fatal(err)
	}

	// Never served, from the moment of the hold, even before the 30 days are up.
	if err := st.Live(id, holdNow); !errors.Is(err, ErrGone) {
		t.Fatalf("Live after hold = %v, want ErrGone", err)
	}
	if _, err := st.Packet(id, holdNow); !errors.Is(err, ErrGone) {
		t.Fatalf("Packet after hold = %v, want ErrGone", err)
	}
	if _, err := st.Preview(id, holdNow); !errors.Is(err, ErrGone) {
		t.Fatalf("Preview after hold = %v, want ErrGone", err)
	}
	for _, name := range contentFiles {
		if _, err := os.Stat(filepath.Join(st.dir, id, name)); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("the live copy of %s is still in the serving directory", name)
		}
	}

	// The expiry sweep, a month and a day later and then 364 days later, leaves the held copy alone.
	for _, at := range []time.Time{holdNow.Add(Lifetime + 24*time.Hour), HoldLifetime(holdNow).Add(-time.Second)} {
		if _, err := st.Sweep(at); err != nil {
			t.Fatal(err)
		}
		if n, err := st.SweepHeld(at); err != nil || n != 0 {
			t.Fatalf("SweepHeld at %s = %d, %v; want 0, nil", at, n, err)
		}
		for name, want := range map[string][]byte{"packet": packet, previewFile: preview, reportedRef: fullLink} {
			got, err := os.ReadFile(heldFile(st, id, name))
			if err != nil || !bytes.Equal(got, want) {
				t.Fatalf("held %s changed or vanished at %s: %v", name, at, err)
			}
		}
	}

	// At one year it goes, and the log says so.
	n, err := st.SweepHeld(HoldLifetime(holdNow))
	if err != nil || n != 1 {
		t.Fatalf("SweepHeld at one year = %d, %v; want 1, nil", n, err)
	}
	if _, err := os.Stat(filepath.Join(st.heldDir(), id)); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("the held copy outlived its year")
	}
	if ids, _ := st.HeldIDs(); len(ids) != 0 {
		t.Fatalf("HeldIDs after the year = %v", ids)
	}
	logText, _ := os.ReadFile(filepath.Join(st.heldDir(), accessLog))
	if !strings.Contains(string(logText), `"event":"delete"`) || !strings.Contains(string(logText), "year up") {
		t.Fatalf("the deletion was not logged: %s", logText)
	}
	if err := st.Live(id, holdNow); !errors.Is(err, ErrGone) {
		t.Fatalf("an id that was held must keep answering 410, got %v", err)
	}
}

func TestWithoutAHoldTheSweepStillDeletesAtThirtyDays(t *testing.T) {
	st, id, _, _ := putLink(t)
	if n, err := st.Sweep(holdNow.Add(Lifetime)); err != nil || n != 1 {
		t.Fatalf("Sweep = %d, %v; want 1, nil", n, err)
	}
	if _, err := os.Stat(st.heldDir()); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("a held directory appeared without a hold")
	}
	_ = id
}

func TestHoldIsRestrictedLoggedAndKeepsNoReaderCall(t *testing.T) {
	st, id, _, _ := putLink(t)
	if err := st.Hold(id, "R1", []byte("full-link"), holdNow); err != nil {
		t.Fatal(err)
	}
	dirInfo, err := os.Stat(st.heldDir())
	if err != nil || dirInfo.Mode().Perm() != 0o700 {
		t.Fatalf("held directory mode = %v, %v; want 0700", dirInfo.Mode().Perm(), err)
	}
	if dirInfo.Mode().Perm()&0o077 != 0 {
		t.Fatal("held directory is open to group or other")
	}
	if filepath.Dir(st.heldDir()) != filepath.Dir(st.dir) || strings.HasPrefix(st.heldDir(), st.dir+string(filepath.Separator)) {
		t.Fatal("the held directory must be a sibling of the links directory, not inside it")
	}
	err = filepath.Walk(filepath.Join(st.heldDir(), id), func(path string, info os.FileInfo, err error) error {
		if err == nil && !info.IsDir() && info.Mode().Perm()&0o077 != 0 {
			t.Errorf("%s is open to group or other (%v)", path, info.Mode().Perm())
		}
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	logText, _ := os.ReadFile(filepath.Join(st.heldDir(), accessLog))
	if !strings.Contains(string(logText), `"event":"hold"`) || !strings.Contains(string(logText), id) {
		t.Fatalf("the hold was not logged: %s", logText)
	}
	if strings.Contains(string(logText), "full-link") {
		t.Fatal("the access log carries the reported link")
	}
}

func TestHoldAgainIsHarmlessAndAnExpiredSweptLinkCanStillBeHeld(t *testing.T) {
	st, id, packet, _ := putLink(t)
	if err := st.Hold(id, "R1", nil, holdNow); err != nil {
		t.Fatal(err)
	}
	if err := st.Hold(id, "R2", []byte("later"), holdNow.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(heldFile(st, id, "packet"))
	if !bytes.Equal(got, packet) {
		t.Fatal("a second hold damaged the held packet")
	}
	if data, err := os.ReadFile(heldFile(st, id, reportedRef)); err != nil || string(data) != "later" {
		t.Fatalf("a second run must add the reported link the first run lacked: %q, %v", data, err)
	}
	var rec holdRecord
	raw, _ := os.ReadFile(heldFile(st, id, holdMeta))
	if err := json.Unmarshal(raw, &rec); err != nil || rec.ReportID != "R1" || !rec.HeldAt.Equal(holdNow) {
		t.Fatalf("a second run must not change the report id or restart the year: %+v, %v", rec, err)
	}
	if err := st.Hold(id, "R3", []byte("other"), holdNow.Add(2*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if data, _ := os.ReadFile(heldFile(st, id, reportedRef)); string(data) != "later" {
		t.Fatal("a third run replaced the reported link")
	}

	// A different link, expired and swept before anyone reported it: only the reported link can be held.
	preview, packet2, _, _ := loadVector(t)
	id2, _, err := st.Put(packet2, preview, holdNow)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.Sweep(holdNow.Add(Lifetime + time.Hour)); err != nil {
		t.Fatal(err)
	}
	if err := st.Hold(id2, "R4", []byte("full-link-2"), holdNow.Add(Lifetime+time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(heldFile(st, id2, "packet")); err == nil {
		t.Fatal("a swept link has no packet to hold")
	}
	if data, _ := os.ReadFile(heldFile(st, id2, reportedRef)); string(data) != "full-link-2" {
		t.Fatalf("reported link = %q", data)
	}
}

func TestHoldRefusesBadInput(t *testing.T) {
	st, id, _, _ := putLink(t)
	for _, row := range []struct {
		name, id, report string
		want             error
	}{
		{"malformed id", "../../etc", "R1", ErrNotFound},
		{"unknown id", strings.Repeat("0", 32), "R1", ErrNotFound},
		{"empty report id", id, "", ErrBadReportID},
		{"report id with a newline", id, "R1\nforged", ErrBadReportID},
		{"report id with a space", id, "R 1", ErrBadReportID},
		{"huge report id", id, strings.Repeat("a", 129), ErrBadReportID},
	} {
		if err := st.Hold(row.id, row.report, nil, holdNow); !errors.Is(err, row.want) {
			t.Errorf("%s: Hold = %v, want %v", row.name, err, row.want)
		}
	}
	if err := st.Live(id, holdNow); err != nil {
		t.Fatalf("a refused hold must not take the link down: %v", err)
	}
	if ids, _ := st.HeldIDs(); len(ids) != 0 {
		t.Fatalf("a refused hold left %v", ids)
	}
}

func TestReleaseNeedsAHeldLinkAndAReasonAndLogsIt(t *testing.T) {
	st, id, _, _ := putLink(t)
	if err := st.ReleaseHeld(id, "law enforcement request", holdNow); !errors.Is(err, ErrNotHeld) {
		t.Fatalf("release of a link that is not held = %v", err)
	}
	if err := st.Hold(id, "R1", nil, holdNow); err != nil {
		t.Fatal(err)
	}
	if err := st.ReleaseHeld(id, "", holdNow); !errors.Is(err, ErrNoReason) {
		t.Fatalf("release without a reason = %v", err)
	}
	if _, err := os.Stat(heldFile(st, id, "packet")); err != nil {
		t.Fatal("a refused release deleted the held copy")
	}
	if err := st.ReleaseHeld(id, "law enforcement request\nforged line", holdNow.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(st.heldDir(), id)); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("release left the held copy")
	}
	logText, _ := os.ReadFile(filepath.Join(st.heldDir(), accessLog))
	lines := strings.Split(strings.TrimSpace(string(logText)), "\n")
	if len(lines) != 2 || !strings.Contains(lines[1], "law enforcement request") {
		t.Fatalf("log should have one hold and one delete line, got %q", lines)
	}
}

func TestSweepHeldKeepsGoingPastABadRecordAndClearsStaleTempFolders(t *testing.T) {
	st, id, _, _ := putLink(t)
	preview, packet, _, _ := loadVector(t)
	id2, _, err := st.Put(packet, preview, holdNow)
	if err != nil {
		t.Fatal(err)
	}
	for _, h := range []string{id, id2} {
		if err := st.Hold(h, "R-"+h[:4], nil, holdNow); err != nil {
			t.Fatal(err)
		}
	}
	// Corrupt whichever record sorts first, so the loop meets it before the good one.
	ids, _ := st.HeldIDs()
	if err := os.WriteFile(heldFile(st, ids[0], holdMeta), []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}
	stale := filepath.Join(st.heldDir(), ".hold-crashed")
	if err := os.Mkdir(stale, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stale, reportedRef), []byte("key"), 0o600); err != nil {
		t.Fatal(err)
	}
	old := holdNow.Add(-2 * time.Hour)
	if err := os.Chtimes(stale, old, old); err != nil {
		t.Fatal(err)
	}
	// The temp folder's age is measured against the sweep time, so sweep a year on.
	n, err := st.SweepHeld(HoldLifetime(holdNow))
	if err == nil || !strings.Contains(err.Error(), ids[0]) {
		t.Fatalf("the bad record should be reported by id, got %v", err)
	}
	if n != 1 {
		t.Fatalf("the good link after the bad one should still be deleted; deleted %d", n)
	}
	if _, err := os.Stat(stale); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("a stale .hold- folder outlived the sweep")
	}
}

// #3120, part 1. The report form is public, so the first link posted for an id must not be the only one
// kept: a junk link posted ahead of the real reporter would lock the real key out of the tip.
func TestEveryDistinctReportedLinkIsKeptUpToTheCapAndCopiesAreNot(t *testing.T) {
	for _, order := range []string{"first run brings the junk link", "first run brought none"} {
		t.Run(order, func(t *testing.T) {
			st, id, _, _ := putLink(t)
			var first []byte
			if order == "first run brings the junk link" {
				first = []byte("https://share.example/l/" + id + "#junk")
			}
			if err := st.Hold(id, "R1", first, holdNow); err != nil {
				t.Fatal(err)
			}
			real := []byte("https://share.example/l/" + id + "#k=REALKEY")
			for i := 0; i < 3; i++ { // the same real link again must not take another slot
				if err := st.Hold(id, "R2", real, holdNow.Add(time.Hour)); err != nil {
					t.Fatal(err)
				}
			}
			found := false
			for n := 1; n <= MaxReportedLinks; n++ {
				if data, err := os.ReadFile(heldFile(st, id, reportedLinkName(n))); err == nil && bytes.Equal(data, real) {
					found = true
				}
			}
			if !found {
				t.Fatal("the real link was displaced by the junk one")
			}
			count := 0
			for n := 1; n <= 10; n++ {
				if _, err := os.Stat(heldFile(st, id, reportedLinkName(n))); err == nil {
					count++
				}
			}
			want := 2
			if first == nil {
				want = 1
			}
			if count != want {
				t.Fatalf("kept %d reported links, want %d (a copy must not take a slot)", count, want)
			}
		})
	}
}

func TestReportedLinksStopAtTheCapAndTheLogSaysSoButTheOwnerCanAddMore(t *testing.T) {
	st, id, _, _ := putLink(t)
	for i := 0; i < MaxReportedLinks+2; i++ {
		link := []byte("link-" + string(rune('a'+i)))
		if err := st.Hold(id, "R1", link, holdNow); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := os.Stat(heldFile(st, id, reportedLinkName(MaxReportedLinks+1))); err == nil {
		t.Fatal("a public report kept more links than the cap")
	}
	if data, _ := os.ReadFile(heldFile(st, id, reportedRef)); string(data) != "link-a" {
		t.Fatalf("the first link changed: %q", data)
	}
	logText, _ := os.ReadFile(filepath.Join(st.heldDir(), accessLog))
	if strings.Count(string(logText), `"event":"link-dropped"`) != 2 {
		t.Fatalf("each dropped link should be logged: %s", logText)
	}
	if strings.Contains(string(logText), "link-f") {
		t.Fatal("the log carries a reported link")
	}
	// The owner's own run adds the real link even when the slots are full.
	if err := st.HoldByOwner(id, "R9", []byte("the-real-one"), holdNow); err != nil {
		t.Fatal(err)
	}
	if data, err := os.ReadFile(heldFile(st, id, reportedLinkName(MaxReportedLinks+1))); err != nil || string(data) != "the-real-one" {
		t.Fatalf("owner hold did not add past the cap: %q, %v", data, err)
	}
}

// Disable promised to keep the content for a hold by hand, but wrote the takedown tombstone, so the next
// daily sweep deleted it. The cap path depends on the promise.
func TestDisabledLinkIsDarkAtOnceAndKeepsItsContentUntilItsOwnExpiry(t *testing.T) {
	st, id, _, _ := putLink(t)
	if err := st.Disable(id); err != nil {
		t.Fatal(err)
	}
	if err := st.Live(id, holdNow); !errors.Is(err, ErrGone) {
		t.Fatalf("Live after Disable = %v, want ErrGone", err)
	}
	if _, err := st.Packet(id, holdNow); !errors.Is(err, ErrGone) {
		t.Fatalf("Packet after Disable = %v, want ErrGone", err)
	}
	if n, err := st.Sweep(holdNow.Add(Lifetime - time.Hour)); err != nil || n != 0 {
		t.Fatalf("Sweep inside the original lifetime = %d, %v; want 0, nil", n, err)
	}
	// A hold by hand still works and has the ciphertext.
	if err := st.HoldByOwner(id, "R1", nil, holdNow.Add(24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(heldFile(st, id, "packet")); err != nil {
		t.Fatalf("the disabled link's ciphertext was gone: %v", err)
	}

	st2, id2, _, _ := putLink(t)
	if err := st2.Disable(id2); err != nil {
		t.Fatal(err)
	}
	if n, err := st2.Sweep(holdNow.Add(Lifetime)); err != nil || n != 1 {
		t.Fatalf("Sweep at the original expiry = %d, %v; want 1, nil", n, err)
	}
	if _, err := os.Stat(filepath.Join(st2.dir, id2, "packet")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("a disabled link's content outlived its 30 days")
	}
	if err := st2.Disable(strings.Repeat("0", 32)); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Disable of an unknown id = %v", err)
	}
}

// #3120, part 2.
func putMore(t *testing.T, st *Store, n int) []string {
	t.Helper()
	preview, packet, _, _ := loadVector(t)
	var ids []string
	for i := 0; i < n; i++ {
		id, _, err := st.Put(packet, preview, holdNow)
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, id)
	}
	return ids
}

func TestHoldRefusesPastACapKeepsTheContentAndLogsTheRefusal(t *testing.T) {
	_, _, packet, preview := putLink(t)
	one := int64(len(packet) + len(preview))
	for name, row := range map[string]struct {
		limits HoldLimits
		when   func(i int) time.Time
	}{
		"items in total":    {HoldLimits{MaxItems: 2, MaxBytes: 1 << 40, MaxItemsPerDay: 100}, func(i int) time.Time { return holdNow.Add(time.Duration(i) * 24 * time.Hour) }},
		"bytes in total":    {HoldLimits{MaxItems: 100, MaxBytes: 2*one + one/2, MaxItemsPerDay: 100}, func(i int) time.Time { return holdNow.Add(time.Duration(i) * 24 * time.Hour) }},
		"new holds per day": {HoldLimits{MaxItems: 100, MaxBytes: 1 << 40, MaxItemsPerDay: 2}, func(i int) time.Time { return holdNow.Add(time.Duration(i) * time.Minute) }},
	} {
		t.Run(name, func(t *testing.T) {
			st, first, _, _ := putLink(t)
			st.HoldLimits = row.limits
			ids := append([]string{first}, putMore(t, st, 3)...)
			for i := 0; i < 2; i++ {
				if err := st.Hold(ids[i], "R", []byte("link"), row.when(i)); err != nil {
					t.Fatalf("hold %d under the cap: %v", i, err)
				}
			}
			err := st.Hold(ids[2], "R", []byte("link"), row.when(2))
			if !errors.Is(err, ErrHoldCap) {
				t.Fatalf("hold past the cap = %v, want ErrHoldCap", err)
			}
			// Refused means refused whole: not held, not taken down, nothing half-written.
			if _, err := os.Stat(filepath.Join(st.heldDir(), ids[2])); err == nil {
				t.Fatal("a refused hold left a held folder")
			}
			if _, err := os.Stat(filepath.Join(st.dir, ids[2], "packet")); err != nil {
				t.Fatalf("a refused hold lost the content: %v", err)
			}
			if err := st.Live(ids[2], row.when(2)); err != nil {
				t.Fatalf("a refused hold must leave the decision to the caller, got %v", err)
			}
			logText, _ := os.ReadFile(filepath.Join(st.heldDir(), accessLog))
			if !strings.Contains(string(logText), `"event":"cap"`) || !strings.Contains(string(logText), ids[2]) {
				t.Fatalf("the refusal is not in the access log: %s", logText)
			}
			// Holding again what is already held is not a new hold, so the cap never blocks it.
			if err := st.Hold(ids[0], "R", []byte("another link"), row.when(2)); err != nil {
				t.Fatalf("re-hold of a held link refused: %v", err)
			}
			// The owner's own run is not capped.
			if err := st.HoldByOwner(ids[2], "R-owner", nil, row.when(2)); err != nil {
				t.Fatalf("owner hold refused: %v", err)
			}
			if _, err := os.Stat(heldFile(st, ids[2], "packet")); err != nil {
				t.Fatal("owner hold did not keep the packet")
			}
		})
	}
}

func TestDailyHoldCapResetsAtTheNextUTCDay(t *testing.T) {
	st, first, _, _ := putLink(t)
	st.HoldLimits = HoldLimits{MaxItemsPerDay: 1}
	ids := append([]string{first}, putMore(t, st, 1)...)
	late := time.Date(2026, 11, 1, 23, 59, 0, 0, time.UTC)
	if err := st.Hold(ids[0], "R", nil, late); err != nil {
		t.Fatal(err)
	}
	if err := st.Hold(ids[1], "R", nil, late.Add(time.Second)); !errors.Is(err, ErrHoldCap) {
		t.Fatalf("second hold the same day = %v", err)
	}
	if err := st.Hold(ids[1], "R", nil, late.Add(2*time.Minute)); err != nil {
		t.Fatalf("hold the next UTC day: %v", err)
	}
}

func TestDefaultHoldLimitsAreFiniteAndAnUnreadableRecordCountsAgainstTheDay(t *testing.T) {
	if l := (HoldLimits{}).withDefaults(); l != DefaultHoldLimits || l.MaxItems <= 0 || l.MaxBytes <= 0 || l.MaxItemsPerDay <= 0 {
		t.Fatalf("zero limits = %+v", l)
	}
	st, first, _, _ := putLink(t)
	st.HoldLimits = HoldLimits{MaxItemsPerDay: 1}
	ids := append([]string{first}, putMore(t, st, 1)...)
	if err := st.Hold(ids[0], "R", nil, holdNow); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(heldFile(st, ids[0], holdMeta), []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := st.Hold(ids[1], "R", nil, holdNow.Add(24*time.Hour)); !errors.Is(err, ErrHoldCap) {
		t.Fatalf("a record that cannot be read must count against the cap, got %v", err)
	}
}

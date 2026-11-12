package clubs

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"spokenmargins.dev/bridge/internal/links"
)

const inviteKey = "INVITEKEY-secret"

func inviteFor(c club) []byte { return []byte("https://example.test/c/" + c.id + "#" + inviteKey) }

func heldFile(s *Store, c club, rel string) string {
	b, err := os.ReadFile(filepath.Join(s.heldDir(), c.id, rel))
	if err != nil {
		return "<" + err.Error() + ">"
	}
	return string(b)
}

func TestHoldKeepsTheCiphertextAndTheLinkThenEndsTheClub(t *testing.T) {
	s, c := open(t), newClub(1)
	made(t, s, c)
	packets := fill(t, s, c, 3)
	if err := s.DisablePost(c.id, c.read, 2, t0); err != nil {
		t.Fatal(err)
	}
	if err := s.Hold(c.id, "form-ABC", inviteFor(c), t0); err != nil {
		t.Fatal(err)
	}
	for rel, want := range map[string]string{
		"header":        string(sealed(links.PartClubHeader, 64, "header")),
		"posts/1":       string(packets[0]),
		"posts/3":       string(packets[2]),
		"disabled/2":    string(packets[1]),
		"reported-link": string(inviteFor(c)),
	} {
		if got := heldFile(s, c, rel); got != want {
			t.Errorf("held %s = %q", rel, got)
		}
	}
	if _, err := os.Stat(filepath.Join(s.heldDir(), c.id, "posts", "2")); err == nil {
		t.Error("the empty place of a disabled post was held")
	}
	// The club is down and kept only its tombstone, and its bytes stopped counting.
	if err := s.Check(c.id, Read, c.read, t0); !errors.Is(err, ErrGone) {
		t.Errorf("held club: %v, want ErrGone", err)
	}
	assertOnlyTombstone(t, s, c.id)
	if s.Total() != 0 {
		t.Errorf("total %d after a hold", s.Total())
	}
	if !s.IsHeld(c.id) || !s.EndedAndHeld(c.id) {
		t.Error("not reported as held")
	}
	// The year is counted from the hold, and the record says nothing but the report id and two dates.
	raw := heldFile(s, c, holdMeta)
	if !strings.Contains(raw, `"reportId":"form-ABC"`) || !strings.Contains(raw, links.HoldLifetime(t0).Format("2006-01-02")) {
		t.Errorf("hold.json: %s", raw)
	}
	// Nothing outside the held folder holds the key.
	filepath.WalkDir(filepath.Dir(s.dir), func(p string, d os.DirEntry, err error) error {
		if err == nil && !d.IsDir() && !strings.HasPrefix(p, s.heldDir()) {
			if b, _ := os.ReadFile(p); strings.Contains(string(b), inviteKey) {
				t.Errorf("the key is in %s", p)
			}
		}
		return nil
	})
	if log := heldFile(s, c, "../access.log"); !strings.Contains(log, `"event":"hold"`) || strings.Contains(log, inviteKey) {
		t.Errorf("access log: %s", log)
	}
}

func TestAHeldClubIsNotHeldTwiceAndAReReportOnlyAddsItsLink(t *testing.T) {
	s, c := open(t), newClub(1)
	made(t, s, c)
	fill(t, s, c, 1)
	if err := s.Hold(c.id, "R1", inviteFor(c), t0); err != nil {
		t.Fatal(err)
	}
	later := t0.AddDate(0, 0, 100)
	if err := s.Hold(c.id, "R2", []byte("https://other.test/c/"+c.id+"#SECOND"), later); err != nil {
		t.Fatal(err)
	}
	// Same link again: nothing added.
	if err := s.Hold(c.id, "R3", inviteFor(c), later); err != nil {
		t.Fatal(err)
	}
	if got := heldFile(s, c, "reported-link-2"); !strings.Contains(got, "SECOND") {
		t.Errorf("second link: %q", got)
	}
	if got := heldFile(s, c, "reported-link-3"); !strings.HasPrefix(got, "<") {
		t.Errorf("a repeated link was added again: %q", got)
	}
	if got := heldFile(s, c, holdMeta); !strings.Contains(got, `"reportId":"R1"`) || strings.Contains(got, "R2") {
		t.Errorf("a later hold changed the record: %s", got)
	}
	// The public path keeps five distinct links and says so when a sixth is dropped; the owner's run keeps more.
	for i := 0; i < 8; i++ {
		s.Hold(c.id, "R", []byte("https://x.test/c/"+c.id+"#K"+string(rune('a'+i))), later)
	}
	if got := heldFile(s, c, "reported-link-5"); strings.HasPrefix(got, "<") {
		t.Errorf("fifth link missing: %q", got)
	}
	if got := heldFile(s, c, "reported-link-6"); !strings.HasPrefix(got, "<") {
		t.Errorf("the public path kept a sixth link: %q", got)
	}
	if log := heldFile(s, c, "../access.log"); !strings.Contains(log, `"event":"link-dropped"`) {
		t.Errorf("no link-dropped line: %s", log)
	}
	if err := s.HoldByOwner(c.id, "R", []byte("https://x.test/c/"+c.id+"#owner"), later); err != nil {
		t.Fatal(err)
	}
	if got := heldFile(s, c, "reported-link-6"); !strings.Contains(got, "owner") {
		t.Errorf("the owner's run was limited: %q", got)
	}
}

func TestAClubThatAlreadyEndedCanStillBeHeldForItsLinkAlone(t *testing.T) {
	s, c := open(t), newClub(1)
	made(t, s, c)
	fill(t, s, c, 1)
	s.Takedown(c.id, t0)
	if err := s.Hold(c.id, "R1", inviteFor(c), t0); err != nil {
		t.Fatal(err)
	}
	if got := heldFile(s, c, "reported-link"); got != string(inviteFor(c)) {
		t.Errorf("link: %q", got)
	}
	if _, err := os.Stat(filepath.Join(s.heldDir(), c.id, "header")); err == nil {
		t.Error("a header was held for a club with none")
	}
	if err := s.Hold(newClub(9).id, "R1", nil, t0); !errors.Is(err, ErrNotFound) {
		t.Errorf("hold of no club: %v", err)
	}
	if err := s.Hold("../x", "R1", nil, t0); !errors.Is(err, ErrNotFound) {
		t.Errorf("hold of a bad id: %v", err)
	}
	for _, bad := range []string{"", "has space", "new\nline", strings.Repeat("x", 129)} {
		if err := s.Hold(c.id, bad, nil, t0); !errors.Is(err, ErrBadReportID) {
			t.Errorf("report id %q: %v", bad, err)
		}
	}
}

func TestHoldCapsRefuseAndLeaveTheClubForTheOwner(t *testing.T) {
	s := open(t)
	s.HoldLimits = links.HoldLimits{MaxItems: 2, MaxItemsPerDay: 50, MaxBytes: 1 << 20}
	var cs []club
	for i := 1; i <= 4; i++ {
		c := newClub(byte(i * 10))
		made(t, s, c)
		fill(t, s, c, 2)
		cs = append(cs, c)
	}
	for _, c := range cs[:2] {
		if err := s.Hold(c.id, "R", nil, t0); err != nil {
			t.Fatal(err)
		}
	}
	// Past the item cap: refused, nothing taken down, a line in the log, and the owner's own run is not capped.
	err := s.Hold(cs[2].id, "R", nil, t0)
	if !errors.Is(err, ErrHoldCap) || !strings.Contains(err.Error(), "held items at the cap of 2") {
		t.Fatalf("third hold: %v", err)
	}
	if got := s.Status(cs[2].id, 0, t0); got != "STILL SERVED" {
		t.Errorf("a refused hold changed the club: %q", got)
	}
	if err := s.ParkLink(cs[2].id, inviteFor(cs[2])); err != nil {
		t.Fatal(err)
	}
	if err := s.Disable(cs[2].id, t0); err != nil {
		t.Fatal(err)
	}
	if log := heldFile(s, cs[0], "../access.log"); !strings.Contains(log, `"event":"cap"`) {
		t.Errorf("no cap line: %s", log)
	}
	if err := s.HoldByOwner(cs[2].id, "NCMEC-1", nil, t0); err != nil {
		t.Fatal(err)
	}
	if got := heldFile(s, cs[2], "reported-link"); got != string(inviteFor(cs[2])) {
		t.Errorf("the parked link did not reach the owner's hold: %q", got)
	}
	// The byte cap and the per-day cap.
	s.HoldLimits = links.HoldLimits{MaxItems: 100, MaxBytes: 100, MaxItemsPerDay: 50}
	if err := s.Hold(cs[3].id, "R", nil, t0); !errors.Is(err, ErrHoldCap) || !strings.Contains(err.Error(), "bytes") {
		t.Errorf("byte cap: %v", err)
	}
	s.HoldLimits = links.HoldLimits{MaxItems: 100, MaxBytes: 1 << 20, MaxItemsPerDay: 3}
	if err := s.Hold(cs[3].id, "R", nil, t0); !errors.Is(err, ErrHoldCap) || !strings.Contains(err.Error(), "today") {
		t.Errorf("day cap: %v", err)
	}
	if err := s.Hold(cs[3].id, "R", nil, t0.AddDate(0, 0, 1)); err != nil {
		t.Errorf("the next day: %v", err)
	}
}

func TestAParkedLinkGoesWithTheClubsContent(t *testing.T) {
	s, c := open(t), newClub(1)
	made(t, s, c)
	fill(t, s, c, 1)
	for i := 0; i < 7; i++ {
		s.ParkLink(c.id, []byte("https://x.test/c/"+c.id+"#K"+string(rune('a'+i))))
	}
	if _, err := os.Stat(s.path(c.id, "reported-link-5")); err != nil {
		t.Error("five links should be parked")
	}
	if _, err := os.Stat(s.path(c.id, "reported-link-6")); err == nil {
		t.Error("a sixth link was parked")
	}
	if err := s.Disable(c.id, t0); err != nil {
		t.Fatal(err)
	}
	if n, err := s.Sweep(t0.AddDate(0, 0, 31)); err != nil || n != 1 {
		t.Fatalf("sweep: %d %v", n, err)
	}
	assertOnlyTombstone(t, s, c.id)
	if err := s.ParkLink(c.id, []byte("x")); !errors.Is(err, ErrGone) {
		t.Errorf("park on an ended club: %v", err)
	}
	if err := s.ParkLink(newClub(5).id, []byte("x")); !errors.Is(err, ErrNotFound) {
		t.Errorf("park on no club: %v", err)
	}
}

func TestTheYearEndsTheHoldAndTheOwnerCanEndItEarly(t *testing.T) {
	s, a, b := open(t), newClub(1), newClub(2)
	for _, c := range []club{a, b} {
		made(t, s, c)
		fill(t, s, c, 1)
		if err := s.Hold(c.id, "R", inviteFor(c), t0); err != nil {
			t.Fatal(err)
		}
	}
	// A crashed hold leaves a temp folder; it goes once an hour old.
	crashed := filepath.Join(s.heldDir(), ".hold-crash")
	os.MkdirAll(filepath.Join(crashed, "posts"), 0o700)
	os.WriteFile(filepath.Join(crashed, "reported-link"), inviteFor(a), 0o600)
	if n, err := s.SweepHeld(t0.AddDate(0, 11, 0)); err != nil || n != 0 {
		t.Fatalf("sweep at eleven months: %d %v", n, err)
	}
	if _, err := os.Stat(crashed); err == nil {
		t.Error("the crashed hold's copy was kept")
	}
	if err := s.ReleaseHeld(a.id, "", t0); !errors.Is(err, ErrNoReason) {
		t.Errorf("release with no reason: %v", err)
	}
	if err := s.ReleaseHeld(a.id, "law enforcement\nreference 7", t0); err != nil {
		t.Fatal(err)
	}
	if s.IsHeld(a.id) {
		t.Error("still held after a release")
	}
	if err := s.ReleaseHeld(a.id, "again", t0); !errors.Is(err, ErrNotHeld) {
		t.Errorf("second release: %v", err)
	}
	if n, err := s.SweepHeld(links.HoldLifetime(t0)); err != nil || n != 1 {
		t.Fatalf("sweep at a year: %d %v", n, err)
	}
	if ids, _ := s.HeldIDs(); len(ids) != 0 {
		t.Errorf("held after a year: %v", ids)
	}
	log := heldFile(s, a, "../access.log")
	if strings.Count(log, `"event":"delete"`) != 2 || !strings.Contains(log, "law enforcement reference 7") {
		t.Errorf("access log: %s", log)
	}
	if strings.Contains(log, inviteKey) {
		t.Error("the key is in the access log")
	}
}

func TestReportedLinksAreReadOnlyFromTheirFilesAndEachReadIsLogged(t *testing.T) {
	s, c := open(t), newClub(1)
	made(t, s, c)
	fill(t, s, c, 1)
	s.Hold(c.id, "R", inviteFor(c), t0)
	s.Hold(c.id, "R", []byte("https://y.test/c/"+c.id+"#SECOND"), t0)
	got, err := s.ReportedLinks(c.id, t0)
	if err != nil || len(got) != 2 || string(got[0]) != string(inviteFor(c)) {
		t.Fatalf("links: %q %v", got, err)
	}
	log := heldFile(s, c, "../access.log")
	if !strings.Contains(log, `"event":"show-reported-link"`) || strings.Contains(log, inviteKey) || strings.Contains(log, "SECOND") {
		t.Errorf("access log: %s", log)
	}
	if _, err := s.ReportedLinks(newClub(3).id, t0); !errors.Is(err, ErrNotHeld) {
		t.Errorf("unheld: %v", err)
	}
	if _, err := s.ReportedLinks("../x", t0); !errors.Is(err, ErrNotFound) {
		t.Errorf("bad id: %v", err)
	}
	// A slot that is a link to a post is never followed, and nothing is logged for the refusal.
	slot := filepath.Join(s.heldDir(), c.id, "reported-link-2")
	os.Remove(slot)
	if err := os.Symlink(filepath.Join(s.heldDir(), c.id, "header"), slot); err != nil {
		t.Skip("no symlinks here")
	}
	lines := strings.Count(heldFile(s, c, "../access.log"), "\n")
	if _, err := s.ReportedLinks(c.id, t0); err == nil {
		t.Error("a symlinked slot was followed")
	}
	if strings.Count(heldFile(s, c, "../access.log"), "\n") != lines {
		t.Error("a refused read was logged as a read")
	}
}

// A hold is a copy that is on disk before the live content goes, so a failure in between never leaves the
// club without either.
func TestAFailedHoldLeavesTheClubUntouched(t *testing.T) {
	s, c := open(t), newClub(1)
	made(t, s, c)
	fill(t, s, c, 2)
	// A held folder that cannot be written: a file where the folder should be.
	if err := os.WriteFile(s.heldDir(), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := s.Hold(c.id, "R", inviteFor(c), t0); err == nil {
		t.Fatal("the hold claimed to work")
	}
	if err := s.Check(c.id, Read, c.read, t0); err != nil {
		t.Errorf("a failed hold changed the club: %v", err)
	}
	if got := item(t, s, c, 2); len(got) == 0 {
		t.Error("a failed hold lost a post")
	}
}

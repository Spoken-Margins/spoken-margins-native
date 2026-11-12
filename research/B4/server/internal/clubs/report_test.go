package clubs

import (
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"spokenmargins.dev/bridge/internal/links"
)

func fill(t *testing.T, s *Store, c club, n int) [][]byte {
	t.Helper()
	var packets [][]byte
	for i := 1; i <= n; i++ {
		p := sealed(links.PartPacket, 64+i, "packet-"+string(rune('0'+i)))
		packets = append(packets, p)
		if seq, err := s.Post(c.id, c.post, p, t0); err != nil || seq != i {
			t.Fatalf("post %d: %d %v", i, seq, err)
		}
	}
	return packets
}

func TestDisablePostKeepsNumbersBytesAndTheCapsHonest(t *testing.T) {
	s, c := open(t), newClub(1)
	made(t, s, c)
	packets := fill(t, s, c, 3)
	before := s.Total()
	if err := s.DisablePost(c.id, c.read, 3, t0); err != nil {
		t.Fatal(err)
	}
	// The last post is the one disabled, and the next still gets a new number.
	if seq, err := s.Post(c.id, c.post, sealed(links.PartPacket, 70, "next"), t0); err != nil || seq != 4 {
		t.Fatalf("post after disabling the last: %d %v, want 4", seq, err)
	}
	if got := item(t, s, c, 3); len(got) != 0 {
		t.Errorf("a disabled post serves %d bytes", len(got))
	}
	if got := item(t, s, c, 2); string(got) != string(packets[1]) {
		t.Error("another post changed")
	}
	list, err := s.List(c.id, c.read, 0, t0)
	if err != nil || len(list) != 4 || list[2].Size != 0 {
		t.Fatalf("list: %+v %v", list, err)
	}
	// The bytes are still on disk and still counted, so the folder cap follows the disk.
	kept, err := os.ReadFile(s.path(c.id, "disabled", "3"))
	if err != nil || string(kept) != string(packets[2]) {
		t.Fatalf("kept bytes: %v", err)
	}
	if want := before + 70; s.Total() != want {
		t.Errorf("total %d, want %d (a disabled post still counts)", s.Total(), want)
	}
	s.recount()
	if want := before + 70; s.Total() != want {
		t.Errorf("total after a recount %d, want %d", s.Total(), want)
	}
	// Doing it again changes nothing.
	if err := s.DisablePost(c.id, c.read, 3, t0); err != nil {
		t.Errorf("second disable: %v", err)
	}
	// Ending the club deletes the disabled bytes with the rest.
	if err := s.Takedown(c.id, t0); err != nil {
		t.Fatal(err)
	}
	assertOnlyTombstone(t, s, c.id)
	if s.Total() != 0 {
		t.Errorf("total after takedown %d", s.Total())
	}
}

func TestDisablePostAnswersLikeEveryOtherRequestToAStranger(t *testing.T) {
	s, c, d := open(t), newClub(1), newClub(2)
	made(t, s, c)
	fill(t, s, c, 2)
	for name, tc := range map[string]struct {
		id, proof string
		seq       int
		want      error
	}{
		"no proof":        {c.id, "", 1, ErrNotFound},
		"the post proof":  {c.id, c.post, 1, ErrNotFound},
		"another proof":   {c.id, d.read, 1, ErrNotFound},
		"unknown club":    {d.id, d.read, 1, ErrNotFound},
		"bad id":          {"../x", c.read, 1, ErrNotFound},
		"post zero":       {c.id, c.read, 0, ErrNotFound},
		"post negative":   {c.id, c.read, -1, ErrNotFound},
		"post not in box": {c.id, c.read, 3, ErrNotFound},
	} {
		if err := s.DisablePost(tc.id, tc.proof, tc.seq, t0); !errors.Is(err, tc.want) {
			t.Errorf("%s: %v, want %v", name, err, tc.want)
		}
	}
	if got := item(t, s, c, 1); len(got) == 0 {
		t.Error("a refused request disabled a post")
	}
	// A member of a club that was disabled is told it is gone.
	s.Disable(c.id, t0)
	if err := s.DisablePost(c.id, c.read, 1, t0); !errors.Is(err, ErrGone) {
		t.Errorf("member, disabled club: %v, want ErrGone", err)
	}
	// The owner's route has no proof, works on a disabled club, and refuses an ended one.
	if err := s.DisablePostByOwner(c.id, 1, t0); err != nil {
		t.Errorf("owner, disabled club: %v", err)
	}
	if err := s.DisablePostByOwner(c.id, 5, t0); !errors.Is(err, ErrNotFound) {
		t.Errorf("owner, no such post: %v", err)
	}
	s.Takedown(c.id, t0)
	if err := s.DisablePostByOwner(c.id, 2, t0); !errors.Is(err, ErrGone) {
		t.Errorf("owner, ended club: %v, want ErrGone", err)
	}
	if err := s.DisablePostByOwner(d.id, 1, t0); !errors.Is(err, ErrNotFound) {
		t.Errorf("owner, no club: %v", err)
	}
}

// A crash between the link and the replacement leaves the post served and its bytes kept: the report can
// be made again, and no number is ever missing.
func TestDisablePostAfterACrashHalfwayCanBeRepeated(t *testing.T) {
	s, c := open(t), newClub(1)
	made(t, s, c)
	packets := fill(t, s, c, 2)
	if err := os.MkdirAll(s.path(c.id, "disabled"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Link(s.path(c.id, "posts", "2"), s.path(c.id, "disabled", "2")); err != nil {
		t.Fatal(err)
	}
	if got := item(t, s, c, 2); string(got) != string(packets[1]) {
		t.Fatal("setup: post not served")
	}
	if err := s.DisablePost(c.id, c.read, 2, t0); err != nil {
		t.Fatal(err)
	}
	if got := item(t, s, c, 2); len(got) != 0 {
		t.Errorf("not disabled after the retry: %d bytes", len(got))
	}
	if b, _ := os.ReadFile(s.path(c.id, "disabled", "2")); string(b) != string(packets[1]) {
		t.Error("the kept bytes changed")
	}
}

func TestADisabledClubKeepsItsContentThirtyDaysFromTheDayItWasDisabled(t *testing.T) {
	s, c := open(t), newClub(1)
	made(t, s, c)
	fill(t, s, c, 1)
	day10 := t0.AddDate(0, 0, 10)
	if err := s.Disable(c.id, day10); err != nil {
		t.Fatal(err)
	}
	// Disabling twice does not restart the thirty days.
	if err := s.Disable(c.id, day10.AddDate(0, 0, 5)); err != nil {
		t.Fatal(err)
	}
	if n, err := s.Sweep(day10.AddDate(0, 0, 29)); err != nil || n != 0 {
		t.Fatalf("sweep on day 29: %d %v, want the content kept", n, err)
	}
	if s.contentBytes(c.id) == 0 {
		t.Fatal("content gone on day 29")
	}
	if n, err := s.Sweep(day10.AddDate(0, 0, 30)); err != nil || n != 1 {
		t.Fatalf("sweep on day 30: %d %v, want the club ended", n, err)
	}
	assertOnlyTombstone(t, s, c.id)
	if raw, _ := os.ReadFile(s.path(c.id, "meta.json")); strings.Contains(string(raw), "disabledDay") {
		t.Errorf("the tombstone keeps the disabled day: %s", raw)
	}
}

func TestReportableMatrix(t *testing.T) {
	s, c := open(t), newClub(1)
	made(t, s, c)
	fill(t, s, c, 1)
	d := newClub(2)
	for name, tc := range map[string]struct {
		id         string
		now        time.Time
		allowEnded bool
		want       error
	}{
		"live":                      {c.id, t0, false, nil},
		"unknown":                   {d.id, t0, false, ErrNotFound},
		"bad id":                    {"zz", t0, true, ErrNotFound},
		"past its lifetime":         {c.id, t0.AddDate(0, 0, 91), false, ErrNotFound},
		"past its lifetime, ending": {c.id, t0.AddDate(0, 0, 91), true, nil},
	} {
		if err := s.Reportable(tc.id, tc.now, tc.allowEnded); !errors.Is(err, tc.want) && err != tc.want {
			t.Errorf("%s: %v, want %v", name, err, tc.want)
		}
	}
	s.Disable(c.id, t0)
	if err := s.Reportable(c.id, t0, false); err != nil {
		t.Errorf("disabled: %v, want reportable (a repeat report is harmless)", err)
	}
	s.Takedown(c.id, t0)
	if err := s.Reportable(c.id, t0, false); !errors.Is(err, ErrNotFound) {
		t.Errorf("ended: %v, want ErrNotFound", err)
	}
	if err := s.Reportable(c.id, t0, true); err != nil {
		t.Errorf("ended, for an abuse report: %v", err)
	}
}

func TestStatusSaysWhatAReportDid(t *testing.T) {
	s, c := open(t), newClub(1)
	made(t, s, c)
	fill(t, s, c, 2)
	for _, tc := range []struct {
		post int
		want string
	}{{0, "STILL SERVED"}, {1, "post STILL SERVED"}, {9, "no such post, club STILL SERVED"}} {
		if got := s.Status(c.id, tc.post, t0); got != tc.want {
			t.Errorf("post %d: %q, want %q", tc.post, got, tc.want)
		}
	}
	s.DisablePost(c.id, c.read, 1, t0)
	if got := s.Status(c.id, 1, t0); got != "post disabled" {
		t.Errorf("after a post report: %q", got)
	}
	if got := s.Status(newClub(2).id, 0, t0); got != "no such club" {
		t.Errorf("unknown: %q", got)
	}
	s.Disable(c.id, t0)
	if got := s.Status(c.id, 1, t0); got != "disabled" {
		t.Errorf("disabled: %q", got)
	}
	if got := s.Status(c.id, 0, t0.AddDate(0, 0, 40)); got != "disabled" {
		t.Errorf("disabled and past its keep, before any sweep: %q", got)
	}
	s.Takedown(c.id, t0)
	if got := s.Status(c.id, 0, t0); got != "taken down" {
		t.Errorf("ended: %q", got)
	}
	live := newClub(3)
	made(t, s, live)
	fill(t, s, live, 1)
	if got := s.Status(live.id, 0, t0.AddDate(0, 0, 100)); got != "expired" {
		t.Errorf("expired: %q", got)
	}
}

// The folder holds exactly what the design declares, including after a post report: the bytes of a disabled
// post under disabled/, an empty place in posts/, and nothing else.
func TestClubFolderAfterAPostReportHoldsExactlyTheDeclaredFiles(t *testing.T) {
	s, c := open(t), newClub(1)
	made(t, s, c)
	fill(t, s, c, 2)
	if err := s.DisablePost(c.id, c.read, 2, t0.AddDate(0, 0, 3)); err != nil {
		t.Fatal(err)
	}
	var files []string
	filepath.WalkDir(s.dir, func(p string, d os.DirEntry, err error) error {
		rel, _ := filepath.Rel(s.dir, p)
		if rel != "." {
			if d.IsDir() {
				rel += "/"
			}
			files = append(files, strings.ReplaceAll(rel, c.id, "<id>"))
		}
		return nil
	})
	sort.Strings(files)
	want := []string{"<id>/", "<id>/disabled/", "<id>/disabled/2", "<id>/header", "<id>/meta.json", "<id>/posts/", "<id>/posts/1", "<id>/posts/2"}
	if strings.Join(files, " ") != strings.Join(want, " ") {
		t.Fatalf("the clubs folder holds %v, want exactly %v", files, want)
	}
	// File times stay at midnight, the new files included.
	for _, rel := range []string{"disabled", "disabled/2", "posts/2", "posts", "."} {
		info, err := os.Stat(s.path(c.id, rel))
		if err != nil {
			t.Fatal(err)
		}
		if mt := info.ModTime().UTC(); !mt.Equal(dayOf(mt)) {
			t.Errorf("%s has time %v, want midnight", rel, info.ModTime())
		}
	}
}

// A disabled club's thirty days are its own: the idle and first-post rules do not shorten them.
func TestADisabledClubIsNotEndedEarlyByTheIdleOrFirstPostRules(t *testing.T) {
	s, c, empty := open(t), newClub(1), newClub(2)
	made(t, s, c)
	fill(t, s, c, 1)
	made(t, s, empty) // never gets a post
	// c was last used 80 days ago and is disabled today (it would end in 10 days by the idle rule); empty is
	// past its 7 first-post days and is disabled today (it would end at the next sweep by that rule).
	day80 := t0.AddDate(0, 0, 80)
	if err := s.Disable(c.id, day80); err != nil {
		t.Fatal(err)
	}
	day8 := t0.AddDate(0, 0, 8)
	if err := s.Disable(empty.id, day8); err != nil {
		t.Fatal(err)
	}
	if n, err := s.Sweep(day8.AddDate(0, 0, 29)); err != nil || n != 0 {
		t.Fatalf("sweep 29 days after the empty club was disabled: %d %v", n, err)
	}
	if n, err := s.Sweep(day80.AddDate(0, 0, 29)); err != nil || n != 1 {
		t.Fatalf("sweep 29 days after c was disabled: %d %v, want only the empty club (30 days gone)", n, err)
	}
	if s.contentBytes(c.id) == 0 {
		t.Error("a disabled club lost its content before its thirty days")
	}
	if n, err := s.Sweep(day80.AddDate(0, 0, 30)); err != nil || n != 1 {
		t.Fatalf("sweep 30 days after: %d %v", n, err)
	}
}

// Disabling a post and posting again must not get round the club's byte cap.
func TestDisabledPostsStillCountAgainstTheClubsByteCap(t *testing.T) {
	s, c := open(t), newClub(1)
	s.Limits.MaxClubBytes = 250
	made(t, s, c)
	post := func() error {
		_, err := s.Post(c.id, c.post, sealed(links.PartPacket, 100, "p"), t0)
		return err
	}
	if err := post(); err != nil {
		t.Fatal(err)
	}
	if err := s.DisablePost(c.id, c.read, 1, t0); err != nil {
		t.Fatal(err)
	}
	if err := post(); err != nil {
		t.Fatal(err)
	}
	if err := s.DisablePost(c.id, c.read, 2, t0); err != nil {
		t.Fatal(err)
	}
	if err := post(); !errors.Is(err, ErrClubFull) {
		t.Errorf("a third post after two disabled ones: %v, want ErrClubFull (200 disabled bytes still held)", err)
	}
}

package clubs

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"spokenmargins.dev/bridge/internal/links"
)

// Reply boxes in the store (#4675, docs/design/reply-mailbox.md, PR plan piece 1).

const replyLink = "0123456789abcdef0123456789abcdef"

// linkEnds is when the test box's link expires: thirty days after t0, as a share link does.
var linkEnds = t0.Add(links.Lifetime)

func madeReply(t *testing.T, s *Store, c club) {
	t.Helper()
	if err := s.CreateReply(c.id, c.readHash, c.postHash, replyLink, linkEnds, t0); err != nil {
		t.Fatalf("create reply: %v", err)
	}
}

func answer(n int, marker string) []byte { return sealed(links.PartPacket, n, marker) }

func TestCreateReplyRefusesWhatItCannotStoreSafely(t *testing.T) {
	s, c := open(t), newClub(1)
	for _, tc := range []struct {
		name                         string
		id, readHash, postHash, link string
		until                        time.Time
	}{
		{"bad id", "XYZ", c.readHash, c.postHash, replyLink, linkEnds},
		{"bad read hash", c.id, c.read[:10], c.postHash, replyLink, linkEnds},
		{"one hash for both", c.id, c.readHash, c.readHash, replyLink, linkEnds},
		{"bad link id", c.id, c.readHash, c.postHash, "nope", linkEnds},
		{"already ended", c.id, c.readHash, c.postHash, replyLink, t0},
	} {
		if err := s.CreateReply(tc.id, tc.readHash, tc.postHash, tc.link, tc.until, t0); !errors.Is(err, ErrInvalid) {
			t.Errorf("%s: %v, want ErrInvalid", tc.name, err)
		}
	}
	madeReply(t, s, c)
	if err := s.CreateReply(c.id, c.readHash, c.postHash, replyLink, linkEnds, t0); !errors.Is(err, ErrConflict) {
		t.Errorf("same box twice: %v, want ErrConflict", err)
	}
	// A club cannot take a reply box's id either, even with the same hashes.
	if _, err := s.Create(c.id, c.readHash, c.postHash, sealed(links.PartClubHeader, 64, "h"), t0); !errors.Is(err, ErrConflict) {
		t.Errorf("club over a reply box: %v, want ErrConflict", err)
	}
	c2 := newClub(2)
	made(t, s, c2)
	if err := s.CreateReply(c2.id, c2.readHash, c2.postHash, replyLink, linkEnds, t0); !errors.Is(err, ErrConflict) {
		t.Errorf("reply box over a club: %v, want ErrConflict", err)
	}
}

func TestAReplyBoxHasNoHeaderAndKeepsEveryAnswerByte(t *testing.T) {
	s, c := open(t), newClub(3)
	madeReply(t, s, c)
	if info := s.Box(c.id); !info.Exists || !info.Reply || info.LinkID != replyLink {
		t.Fatalf("Box = %+v", info)
	}
	if info := s.Box(newClub(4).id); info.Exists || info.Reply {
		t.Fatalf("Box of an unknown id = %+v", info)
	}
	if _, err := s.Item(c.id, c.read, 0, t0); !errors.Is(err, ErrNotFound) {
		t.Fatalf("item 0 of a reply box: %v, want ErrNotFound", err)
	}
	a := answer(300, "answer-1")
	if seq, err := s.Post(c.id, c.post, a, t0); err != nil || seq != 1 {
		t.Fatalf("post: %d %v", seq, err)
	}
	if got := item(t, s, c, 1); string(got) != string(a) {
		t.Fatal("answer changed in the box")
	}
	// The post proof cannot read and the read proof cannot post.
	if _, err := s.List(c.id, c.post, 0, t0); !errors.Is(err, ErrNotFound) {
		t.Errorf("list with the post proof: %v", err)
	}
	if _, err := s.Post(c.id, c.read, a, t0); !errors.Is(err, ErrNotFound) {
		t.Errorf("post with the read proof: %v", err)
	}
}

func TestReplyBoxCaps(t *testing.T) {
	if ReplyMaxPosts != 20 || ReplyMaxBoxBytes != 50<<20 || ReplyMaxPostBytes != 10<<20 {
		t.Fatal("the reply caps are not the design's 20 posts, 50 MB and 10 MB")
	}
	s, c := open(t), newClub(5)
	madeReply(t, s, c)
	if _, err := s.Post(c.id, c.post, answer(ReplyMaxPostBytes+1, "big"), t0); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("10 MB plus one byte: %v, want ErrTooLarge", err)
	}
	for i := 1; i <= ReplyMaxPosts; i++ {
		if _, err := s.Post(c.id, c.post, answer(100, "a"), t0); err != nil {
			t.Fatalf("post %d: %v", i, err)
		}
	}
	if _, err := s.Post(c.id, c.post, answer(100, "a"), t0); !errors.Is(err, ErrClubFull) {
		t.Fatalf("21st post: %v, want ErrClubFull", err)
	}

	// 50 MB in all: five full answers fit, and one more byte does not.
	s, c = open(t), newClub(6)
	madeReply(t, s, c)
	for i := 0; i < 5; i++ {
		if _, err := s.Post(c.id, c.post, answer(ReplyMaxPostBytes, "full"), t0); err != nil {
			t.Fatalf("full answer %d: %v", i, err)
		}
	}
	if _, err := s.Post(c.id, c.post, answer(links.SealedOverhead, ""), t0); !errors.Is(err, ErrClubFull) {
		t.Fatalf("past 50 MB: %v, want ErrClubFull", err)
	}
	// Reply boxes count against the clubs' one pool.
	if s.Total() != 5*int64(ReplyMaxPostBytes) {
		t.Fatalf("pool total %d", s.Total())
	}
	s.Limits.MaxTotalBytes = s.Total() + 10
	c2 := newClub(7)
	madeReply(t, s, c2)
	if _, err := s.Post(c2.id, c2.post, answer(100, "x"), t0); !errors.Is(err, ErrFull) {
		t.Fatalf("past the pool: %v, want ErrFull", err)
	}
}

func TestAReplyBoxIsNotEndedByTheFirstPostOrIdleRules(t *testing.T) {
	s, c := open(t), newClub(8)
	madeReply(t, s, c)
	// Day 29, nobody has answered or read: still open.
	day29 := t0.AddDate(0, 0, 29)
	if n, err := s.Sweep(day29); err != nil || n != 0 {
		t.Fatalf("sweep on day 29: %d %v", n, err)
	}
	if _, err := s.Post(c.id, c.post, answer(100, "late"), day29); err != nil {
		t.Fatalf("post on day 29: %v", err)
	}
}

func TestPostsStopWithTheLinkAndReadsGoOnSevenDays(t *testing.T) {
	s, c := open(t), newClub(9)
	madeReply(t, s, c)
	if _, err := s.Post(c.id, c.post, answer(100, "one"), linkEnds.Add(-time.Second)); err != nil {
		t.Fatalf("post just before the link ends: %v", err)
	}
	if _, err := s.Post(c.id, c.post, answer(100, "two"), linkEnds); !errors.Is(err, ErrGone) {
		t.Fatalf("post as the link ends: %v, want ErrGone", err)
	}
	// A stranger still learns nothing.
	if _, err := s.Post(c.id, newClub(10).post, answer(100, "x"), linkEnds); !errors.Is(err, ErrNotFound) {
		t.Fatalf("stranger after the link: %v, want ErrNotFound", err)
	}
	reads := linkEnds.AddDate(0, 0, ReplyReadDays)
	if list, err := s.List(c.id, c.read, 0, reads.Add(-time.Second)); err != nil || len(list) != 1 {
		t.Fatalf("read on the last day: %v %v", list, err)
	}
	if n, err := s.Sweep(reads.Add(-time.Second)); err != nil || n != 0 {
		t.Fatalf("sweep before readsUntil: %d %v", n, err)
	}
	if _, err := s.List(c.id, c.read, 0, reads); !errors.Is(err, ErrGone) {
		t.Fatalf("read at readsUntil: %v, want ErrGone", err)
	}
	if n, err := s.Sweep(reads); err != nil || n != 1 {
		t.Fatalf("sweep at readsUntil: %d %v", n, err)
	}
	assertOnlyTombstone(t, s, c.id)
	if s.Total() != 0 {
		t.Fatalf("an ended box still counts %d bytes", s.Total())
	}
	if info := s.Box(c.id); info.LinkID != "" {
		t.Fatal("an ended box still names its link")
	}
}

func TestAClosedBoxTakesNoPostsAndItsSenderStillReadsAndReports(t *testing.T) {
	s, c := open(t), newClub(11)
	madeReply(t, s, c)
	for i := 0; i < 2; i++ {
		if _, err := s.Post(c.id, c.post, answer(100, "a"), t0); err != nil {
			t.Fatal(err)
		}
	}
	// Only the read proof closes, and only a reply box.
	if err := s.Close(c.id, c.post, t0); !errors.Is(err, ErrNotFound) {
		t.Fatalf("close with the post proof: %v, want ErrNotFound", err)
	}
	if err := s.Close(c.id, newClub(12).read, t0); !errors.Is(err, ErrNotFound) {
		t.Fatalf("close by a stranger: %v, want ErrNotFound", err)
	}
	if err := s.Close(newClub(13).id, c.read, t0); !errors.Is(err, ErrNotFound) {
		t.Fatalf("close an unknown id: %v, want ErrNotFound", err)
	}
	cl := newClub(14)
	made(t, s, cl)
	if err := s.Close(cl.id, cl.read, t0); !errors.Is(err, ErrNotFound) {
		t.Fatalf("close a club: %v, want ErrNotFound", err)
	}
	if err := s.Close(c.id, c.read, t0); err != nil {
		t.Fatalf("close: %v", err)
	}
	if err := s.Close(c.id, c.read, t0); err != nil {
		t.Fatalf("close again: %v, want nil", err)
	}
	if _, err := s.Post(c.id, c.post, answer(100, "after"), t0); !errors.Is(err, ErrGone) {
		t.Fatalf("post to a closed box: %v, want ErrGone", err)
	}
	if err := s.Check(c.id, Post, newClub(15).post, t0); !errors.Is(err, ErrNotFound) {
		t.Fatalf("stranger posting to a closed box: %v, want ErrNotFound", err)
	}
	if list, err := s.List(c.id, c.read, 0, t0); err != nil || len(list) != 2 {
		t.Fatalf("list a closed box: %v %v", list, err)
	}
	item(t, s, c, 2)
	// A post-level report with the read proof still works on a closed box.
	if err := s.DisablePost(c.id, c.read, 1, t0); err != nil {
		t.Fatalf("post report on a closed box: %v", err)
	}
	if err := s.Reportable(c.id, t0, false); err != nil {
		t.Fatalf("closed box not reportable: %v", err)
	}
	if got := s.Status(c.id, 0, t0); !strings.Contains(got, "closed") {
		t.Errorf("status of a closed box: %q", got)
	}
	// A whole-box report disables it, closed or not.
	if err := s.Disable(c.id, t0); err != nil {
		t.Fatal(err)
	}
	if _, err := s.List(c.id, c.read, 0, t0); !errors.Is(err, ErrGone) {
		t.Fatalf("list a disabled box: %v, want ErrGone", err)
	}
	if err := s.Close(c.id, c.read, t0); err != nil {
		t.Fatalf("close a disabled box: %v, want nil", err)
	}
	// Closed boxes end on the same day as open ones.
	s2, c2 := open(t), newClub(16)
	madeReply(t, s2, c2)
	if err := s2.Close(c2.id, c2.read, t0); err != nil {
		t.Fatal(err)
	}
	if n, _ := s2.Sweep(linkEnds.AddDate(0, 0, ReplyReadDays)); n != 1 {
		t.Fatal("a closed box was not ended at readsUntil")
	}
	if err := s2.Close(c2.id, c2.read, linkEnds.AddDate(0, 0, ReplyReadDays)); err != nil {
		t.Fatalf("close an ended box: %v, want nil", err)
	}
}

func TestReplyFolderHoldsExactlyTheDeclaredFiles(t *testing.T) {
	s, c := open(t), newClub(17)
	madeReply(t, s, c)
	for i := 0; i < 2; i++ {
		if _, err := s.Post(c.id, c.post, answer(64, "p"), t0); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.Close(c.id, c.read, t0.AddDate(0, 0, 1)); err != nil {
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
	want := []string{"<id>/", "<id>/meta.json", "<id>/posts/", "<id>/posts/1", "<id>/posts/2"}
	if strings.Join(files, " ") != strings.Join(want, " ") {
		t.Fatalf("the clubs folder holds %v, want exactly %v", files, want)
	}
	raw, _ := os.ReadFile(s.path(c.id, "meta.json"))
	var fields map[string]any
	if err := json.Unmarshal(raw, &fields); err != nil {
		t.Fatal(err)
	}
	var names []string
	for n := range fields {
		names = append(names, n)
	}
	sort.Strings(names)
	if got, want := strings.Join(names, ","), "createdDay,kind,lastActiveDay,linkId,postHash,postsUntil,readHash,state"; got != want {
		t.Fatalf("meta.json fields %s, want exactly %s:\n%s", got, want, raw)
	}
	if fields["kind"] != "reply" || fields["linkId"] != replyLink || fields["state"] != "closed" {
		t.Fatalf("meta.json %s", raw)
	}
	if strings.Contains(string(raw), c.read) || strings.Contains(string(raw), c.post) {
		t.Fatal("meta.json holds a proof")
	}
	// Every time is still midnight.
	filepath.WalkDir(s.dir, func(p string, d os.DirEntry, err error) error {
		if info, err := os.Stat(p); err == nil && p != s.dir {
			if mt := info.ModTime().UTC(); mt.Hour() != 0 || mt.Minute() != 0 || mt.Second() != 0 {
				t.Errorf("%s has time %v", p, mt)
			}
		}
		return nil
	})
	// The tombstone keeps no link id.
	if err := s.Takedown(c.id, t0); err != nil {
		t.Fatal(err)
	}
	raw, _ = os.ReadFile(s.path(c.id, "meta.json"))
	if strings.Contains(string(raw), replyLink) || strings.Contains(string(raw), "linkId") {
		t.Fatalf("tombstone names its link: %s", raw)
	}
}

func TestDiscardReplyRemovesOnlyAnUnusedBoxOfThatLink(t *testing.T) {
	s, c := open(t), newClub(18)
	madeReply(t, s, c)
	if err := s.DiscardReply(c.id, "ffffffffffffffffffffffffffffffff", t0); err == nil {
		t.Fatal("discarded another link's box")
	}
	if err := s.DiscardReply(c.id, replyLink, t0); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(s.path(c.id)); !os.IsNotExist(err) {
		t.Fatal("the discarded box's folder is still there")
	}
	cl := newClub(19)
	made(t, s, cl)
	if err := s.DiscardReply(cl.id, replyLink, t0); err == nil {
		t.Fatal("discarded a club")
	}
	madeReply(t, s, c)
	if _, err := s.Post(c.id, c.post, answer(64, "p"), t0); err != nil {
		t.Fatal(err)
	}
	if err := s.DiscardReply(c.id, replyLink, t0); err == nil {
		t.Fatal("discarded a box with an answer")
	}
}

func TestReplyCountsCountLiveBoxesAndAnsweredOnes(t *testing.T) {
	s := open(t)
	made(t, s, newClub(20)) // a club is not counted
	a, b, ended := newClub(21), newClub(22), newClub(23)
	madeReply(t, s, a)
	madeReply(t, s, b)
	madeReply(t, s, ended)
	if _, err := s.Post(a.id, a.post, answer(64, "p"), t0); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Post(ended.id, ended.post, answer(64, "p"), t0); err != nil {
		t.Fatal(err)
	}
	if err := s.Takedown(ended.id, t0); err != nil {
		t.Fatal(err)
	}
	boxes, answered, err := s.ReplyCounts(t0)
	if err != nil || boxes != 2 || answered != 1 {
		t.Fatalf("counts %d %d %v, want 2 boxes, 1 answered", boxes, answered, err)
	}
	if boxes, _, _ := s.ReplyCounts(linkEnds.AddDate(0, 0, ReplyReadDays)); boxes != 0 {
		t.Fatalf("boxes past readsUntil still counted: %d", boxes)
	}
}

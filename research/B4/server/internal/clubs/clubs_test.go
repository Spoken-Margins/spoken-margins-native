package clubs

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"spokenmargins.dev/bridge/internal/links"
)

var t0 = time.Date(2026, 11, 12, 13, 14, 15, 678, time.UTC)

// sealed is a part with the real sealed header, padded to n bytes. The server checks only the header and
// the length, so the rest can be anything; marker makes each part tell apart.
func sealed(part byte, n int, marker string) []byte {
	b := append([]byte("SMLINK"), 1, part)
	b = append(b, make([]byte, n-8)...)
	copy(b[8:], marker)
	return b
}

type club struct {
	id, read, post, readHash, postHash string
}

// newClub makes the proofs and hashes a phone would, from fixed bytes so a failure is repeatable.
func newClub(seed byte) club {
	bytes32 := func(tag byte) []byte {
		b := make([]byte, 32)
		for i := range b {
			b[i] = seed + tag + byte(i)
		}
		return b
	}
	hash := func(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }
	r, p := bytes32(1), bytes32(2)
	id := bytes32(3)[:16]
	return club{id: hex.EncodeToString(id), read: hex.EncodeToString(r), post: hex.EncodeToString(p), readHash: hash(r), postHash: hash(p)}
}

func open(t *testing.T) *Store {
	t.Helper()
	s, err := OpenStore(filepath.Join(t.TempDir(), "clubs"))
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func made(t *testing.T, s *Store, c club) {
	t.Helper()
	if ok, err := s.Create(c.id, c.readHash, c.postHash, sealed(links.PartClubHeader, 64, "header"), t0); err != nil || !ok {
		t.Fatalf("create: %v %v", ok, err)
	}
}

// item reads one item of the box with the read proof.
func item(t *testing.T, s *Store, c club, seq int) []byte {
	t.Helper()
	f, err := s.Item(c.id, c.read, seq, t0)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	b, err := io.ReadAll(f)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestCreatePostListAndFetchKeepEveryByte(t *testing.T) {
	s, c := open(t), newClub(1)
	made(t, s, c)
	header := sealed(links.PartClubHeader, 64, "header")
	if got := item(t, s, c, 0); !bytes.Equal(got, header) {
		t.Fatalf("header changed on its way through the box")
	}
	var posts [][]byte
	for i := 0; i < 3; i++ {
		p := sealed(links.PartPacket, 100+i, "post"+string(rune('a'+i)))
		posts = append(posts, p)
		seq, err := s.Post(c.id, c.post, p, t0)
		if err != nil || seq != i+1 {
			t.Fatalf("post %d: seq %d, %v", i, seq, err)
		}
	}
	list, err := s.List(c.id, c.read, 0, t0)
	if err != nil || len(list) != 3 {
		t.Fatalf("list: %v %v", list, err)
	}
	for i, p := range list {
		if p.Seq != i+1 || p.Size != int64(len(posts[i])) {
			t.Errorf("list[%d] = %+v", i, p)
		}
		if got := item(t, s, c, p.Seq); !bytes.Equal(got, posts[i]) {
			t.Errorf("post %d changed on its way through the box", p.Seq)
		}
	}
	if after, _ := s.List(c.id, c.read, 2, t0); len(after) != 1 || after[0].Seq != 3 {
		t.Errorf("after=2: %v", after)
	}
	if after, _ := s.List(c.id, c.read, 3, t0); len(after) != 0 {
		t.Errorf("after=3: %v", after)
	}
}

func TestCreateRepeatAndConflict(t *testing.T) {
	s, c := open(t), newClub(1)
	made(t, s, c)
	// A retry after a lost answer: same id, same hashes. Not an error and nothing changes.
	if ok, err := s.Create(c.id, c.readHash, c.postHash, sealed(links.PartClubHeader, 80, "other header"), t0.Add(time.Minute)); err != nil || ok {
		t.Fatalf("repeat: %v %v, want no error and not created", ok, err)
	}
	if got := item(t, s, c, 0); !bytes.Equal(got, sealed(links.PartClubHeader, 64, "header")) {
		t.Fatalf("a repeat replaced the header")
	}
	other := newClub(9)
	if _, err := s.Create(c.id, other.readHash, other.postHash, sealed(links.PartClubHeader, 64, "h"), t0); !errors.Is(err, ErrConflict) {
		t.Fatalf("same id, other hashes: %v, want ErrConflict", err)
	}
	if _, err := s.Create(c.id, c.readHash, other.postHash, sealed(links.PartClubHeader, 64, "h"), t0); !errors.Is(err, ErrConflict) {
		t.Fatalf("same id, one other hash: %v, want ErrConflict", err)
	}
}

func TestCreateRefusesWhatItCannotStoreSafely(t *testing.T) {
	s, c := open(t), newClub(1)
	header := sealed(links.PartClubHeader, 64, "h")
	for name, tc := range map[string]struct {
		id, rh, ph string
		header     []byte
		want       error
	}{
		"short id":              {c.id[:30], c.readHash, c.postHash, header, ErrInvalid},
		"upper-case id":         {strings.ToUpper(c.id), c.readHash, c.postHash, header, ErrInvalid},
		"id with a slash":       {"../" + c.id[3:], c.readHash, c.postHash, header, ErrInvalid},
		"short hash":            {c.id, c.readHash[:60], c.postHash, header, ErrInvalid},
		"non-hex hash":          {c.id, strings.Repeat("g", 64), c.postHash, header, ErrInvalid},
		"empty header":          {c.id, c.readHash, c.postHash, nil, ErrInvalid},
		"one hash for both":     {c.id, c.readHash, c.readHash, header, ErrInvalid},
		"a packet as a header":  {c.id, c.readHash, c.postHash, sealed(links.PartPacket, 64, "h"), ErrUnsealed},
		"a preview as a header": {c.id, c.readHash, c.postHash, sealed(links.PartPreview, 64, "h"), ErrUnsealed},
		"plain text header":     {c.id, c.readHash, c.postHash, bytes.Repeat([]byte("x"), 64), ErrUnsealed},
		"header too short":      {c.id, c.readHash, c.postHash, sealed(links.PartClubHeader, 40, "")[:30], ErrUnsealed},
		"header too large":      {c.id, c.readHash, c.postHash, sealed(links.PartClubHeader, MaxHeaderBytes+1, "h"), ErrTooLarge},
	} {
		if _, err := s.Create(tc.id, tc.rh, tc.ph, tc.header, t0); !errors.Is(err, tc.want) {
			t.Errorf("%s: %v, want %v", name, err, tc.want)
		}
	}
	if entries, _ := os.ReadDir(s.dir); len(entries) != 0 {
		t.Errorf("a refused create left %d entries in the clubs folder", len(entries))
	}
}

func TestPostRefusesWhatIsNotASealedPacket(t *testing.T) {
	s, c := open(t), newClub(1)
	made(t, s, c)
	for name, tc := range map[string]struct {
		packet []byte
		want   error
	}{
		"empty":              {nil, ErrUnsealed},
		"plain text":         {bytes.Repeat([]byte("hello"), 20), ErrUnsealed},
		"a header as a post": {sealed(links.PartClubHeader, 64, "p"), ErrUnsealed},
		"a preview":          {sealed(links.PartPreview, 64, "p"), ErrUnsealed},
		"too short":          {sealed(links.PartPacket, 40, "p")[:30], ErrUnsealed},
		"too large":          {sealed(links.PartPacket, MaxPostBytes+1, "p"), ErrTooLarge},
	} {
		if _, err := s.Post(c.id, c.post, tc.packet, t0); !errors.Is(err, tc.want) {
			t.Errorf("%s: %v, want %v", name, err, tc.want)
		}
	}
	if list, _ := s.List(c.id, c.read, 0, t0); len(list) != 0 {
		t.Errorf("a refused post was kept: %v", list)
	}
	if _, err := s.Post(c.id, c.post, sealed(links.PartPacket, MaxPostBytes, "max"), t0); err != nil {
		t.Errorf("a post of exactly the maximum size: %v", err)
	}
}

// A wrong proof, a proof of the other kind, a malformed one and an id that never existed all get the same
// answer, so a stranger learns nothing about which ids are clubs.
func TestWrongOrMissingProofLooksLikeNoClub(t *testing.T) {
	s, c := open(t), newClub(1)
	made(t, s, c)
	if _, err := s.Post(c.id, c.post, sealed(links.PartPacket, 64, "p"), t0); err != nil {
		t.Fatal(err)
	}
	other := newClub(7)
	neverMade := newClub(40)
	for name, tc := range map[string]struct{ id, proof string }{
		"unknown club, a real-looking proof": {neverMade.id, neverMade.read},
		"wrong proof":                        {c.id, other.read},
		"the post proof where read is asked": {c.id, c.post},
		"empty proof":                        {c.id, ""},
		"short proof":                        {c.id, c.read[:62]},
		"upper-case proof":                   {c.id, strings.ToUpper(c.read)},
		"bad id":                             {"not-an-id", c.read},
	} {
		if _, err := s.List(tc.id, tc.proof, 0, t0); !errors.Is(err, ErrNotFound) {
			t.Errorf("list, %s: %v, want ErrNotFound", name, err)
		}
		if f, err := s.Item(tc.id, tc.proof, 1, t0); !errors.Is(err, ErrNotFound) {
			if f != nil {
				f.Close()
			}
			t.Errorf("item, %s: %v, want ErrNotFound", name, err)
		}
		if err := s.Check(tc.id, Read, tc.proof, t0); !errors.Is(err, ErrNotFound) {
			t.Errorf("check, %s: %v, want ErrNotFound", name, err)
		}
	}
	// The read proof does not post, and the post proof does not read.
	if _, err := s.Post(c.id, c.read, sealed(links.PartPacket, 64, "p"), t0); !errors.Is(err, ErrNotFound) {
		t.Errorf("post with the read proof: %v, want ErrNotFound", err)
	}
	if err := s.Check(c.id, Read, c.post, t0); !errors.Is(err, ErrNotFound) {
		t.Errorf("read with the post proof: %v, want ErrNotFound", err)
	}
}

func TestACapOnPostsBytesAndTheWholeFolder(t *testing.T) {
	s, c := open(t), newClub(1)
	s.Limits = Limits{MaxPosts: 3, MaxClubBytes: 400, MaxTotalBytes: 1 << 20}
	made(t, s, c)
	for i := 0; i < 3; i++ {
		if _, err := s.Post(c.id, c.post, sealed(links.PartPacket, 100, "p"), t0); err != nil {
			t.Fatalf("post %d: %v", i, err)
		}
	}
	if _, err := s.Post(c.id, c.post, sealed(links.PartPacket, 100, "p"), t0); !errors.Is(err, ErrClubFull) {
		t.Fatalf("a fourth post: %v, want ErrClubFull", err)
	}
	// Bytes: 3 posts of 100 leave room for 100 more, not 101.
	s.Limits.MaxPosts = 10
	if _, err := s.Post(c.id, c.post, sealed(links.PartPacket, 101, "p"), t0); !errors.Is(err, ErrClubFull) {
		t.Fatalf("101 bytes into 100 of room: %v, want ErrClubFull", err)
	}
	if seq, err := s.Post(c.id, c.post, sealed(links.PartPacket, 100, "p"), t0); err != nil || seq != 4 {
		t.Fatalf("100 bytes into 100 of room: %d %v", seq, err)
	}
	// The whole folder: a second club and its header, then no room for a post.
	d := newClub(5)
	s.Limits.MaxTotalBytes = s.Total() + 64 + 50
	if ok, err := s.Create(d.id, d.readHash, d.postHash, sealed(links.PartClubHeader, 64, "h"), t0); err != nil || !ok {
		t.Fatalf("second club: %v %v", ok, err)
	}
	if _, err := s.Post(d.id, d.post, sealed(links.PartPacket, 51, "p"), t0); !errors.Is(err, ErrFull) {
		t.Fatalf("a post past the folder's cap: %v, want ErrFull", err)
	}
	if _, err := s.Post(d.id, d.post, sealed(links.PartPacket, 50, "p"), t0); err != nil {
		t.Fatalf("a post that fits the folder's cap: %v", err)
	}
	e := newClub(11)
	if _, err := s.Create(e.id, e.readHash, e.postHash, sealed(links.PartClubHeader, 64, "h"), t0); !errors.Is(err, ErrFull) {
		t.Fatalf("a new club past the folder's cap: %v, want ErrFull", err)
	}
}

func TestTheDefaultCapsAreTheDesignsNumbers(t *testing.T) {
	var l Limits
	if l.posts() != 200 || l.club() != 200<<20 || l.total() != 5<<30 || MaxPostBytes != 20<<20 {
		t.Fatalf("defaults %d posts, %d per club, %d in all, %d per post; the design says 200, 200 MB, 5 GB, 20 MB", l.posts(), l.club(), l.total(), MaxPostBytes)
	}
	if FirstPostDays != 7 || IdleDays != 90 {
		t.Fatalf("lifetimes %d and %d days, the design says 7 and 90", FirstPostDays, IdleDays)
	}
}

func TestFolderTotalIsCountedAgainAfterARestartAndFallsWhenAClubEnds(t *testing.T) {
	s, c := open(t), newClub(1)
	made(t, s, c)
	if _, err := s.Post(c.id, c.post, sealed(links.PartPacket, 1000, "p"), t0); err != nil {
		t.Fatal(err)
	}
	if got := s.Total(); got != 64+1000 {
		t.Fatalf("total %d, want 1064", got)
	}
	again, err := OpenStore(s.dir)
	if err != nil {
		t.Fatal(err)
	}
	if got := again.Total(); got != 1064 {
		t.Fatalf("total after reopen %d, want 1064", got)
	}
	if err := again.Takedown(c.id, t0); err != nil {
		t.Fatal(err)
	}
	if got := again.Total(); got != 0 {
		t.Fatalf("total after a takedown %d, want 0", got)
	}
	third, _ := OpenStore(s.dir)
	if got := third.Total(); got != 0 {
		t.Fatalf("total after reopening a gone club %d, want 0", got)
	}
}

func TestAClubWithNoPostInItsFirstSevenDaysEnds(t *testing.T) {
	s, c := open(t), newClub(1)
	made(t, s, c)
	day := func(n int) time.Time { return dayOf(t0).AddDate(0, 0, n).Add(5 * time.Hour) }
	// Reading does not keep an empty club alive.
	for n := 0; n < 7; n++ {
		if _, err := s.List(c.id, c.read, 0, day(n)); err != nil {
			t.Fatalf("day %d: %v", n, err)
		}
	}
	if n, err := s.Sweep(day(6)); err != nil || n != 0 {
		t.Fatalf("sweep on day 6: %d %v", n, err)
	}
	if _, err := s.List(c.id, c.read, 0, day(7)); !errors.Is(err, ErrGone) {
		t.Fatalf("day 7, no post: %v, want ErrGone for a member", err)
	}
	if n, err := s.Sweep(day(7)); err != nil || n != 1 {
		t.Fatalf("sweep on day 7: %d %v, want 1", n, err)
	}
	assertOnlyTombstone(t, s, c.id)
}

func TestAClubWithAPostLivesNinetyDaysFromItsLastUse(t *testing.T) {
	s, c := open(t), newClub(1)
	made(t, s, c)
	day := func(n int) time.Time { return dayOf(t0).AddDate(0, 0, n).Add(9 * time.Hour) }
	if _, err := s.Post(c.id, c.post, sealed(links.PartPacket, 64, "p"), day(3)); err != nil {
		t.Fatal(err)
	}
	// A read on day 80 restarts the ninety days.
	if _, err := s.List(c.id, c.read, 0, day(80)); err != nil {
		t.Fatal(err)
	}
	if n, _ := s.Sweep(day(169)); n != 0 {
		t.Fatalf("day 169, 89 days after the last read: swept %d, want 0", n)
	}
	if _, err := s.List(c.id, c.read, 0, day(169)); err != nil {
		t.Fatalf("day 169: %v, want still served", err)
	}
	// The read on day 169 counted too. Left alone from there it ends on day 259.
	if n, _ := s.Sweep(day(258)); n != 0 {
		t.Fatalf("day 258: swept %d, want 0", n)
	}
	if n, err := s.Sweep(day(259)); err != nil || n != 1 {
		t.Fatalf("day 259, 90 days on: %d %v, want 1", n, err)
	}
	if _, err := s.List(c.id, c.read, 0, day(259)); !errors.Is(err, ErrGone) {
		t.Fatalf("after it ended: %v, want ErrGone for a member", err)
	}
	if err := s.Check(c.id, Read, newClub(2).read, day(259)); !errors.Is(err, ErrNotFound) {
		t.Fatalf("after it ended, a stranger: %v, want ErrNotFound", err)
	}
	assertOnlyTombstone(t, s, c.id)
	// An id that ended cannot be made again, by the people who made it or anyone else.
	if _, err := s.Create(c.id, c.readHash, c.postHash, sealed(links.PartClubHeader, 64, "h"), day(260)); !errors.Is(err, ErrGone) {
		t.Fatalf("make it again: %v, want ErrGone", err)
	}
	other := newClub(8)
	if _, err := s.Create(c.id, other.readHash, other.postHash, sealed(links.PartClubHeader, 64, "h"), day(260)); !errors.Is(err, ErrConflict) {
		t.Fatalf("make the id with other proofs: %v, want ErrConflict", err)
	}
}

func TestExpiryWorksWithoutASweep(t *testing.T) {
	s, c := open(t), newClub(1)
	made(t, s, c)
	late := t0.AddDate(0, 0, 100)
	if _, err := s.Post(c.id, c.post, sealed(links.PartPacket, 64, "p"), late); !errors.Is(err, ErrGone) {
		t.Fatalf("a post into a club that ran out: %v, want ErrGone", err)
	}
}

func assertOnlyTombstone(t *testing.T, s *Store, id string) {
	t.Helper()
	entries, err := os.ReadDir(s.path(id))
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, e := range entries {
		names = append(names, e.Name())
	}
	if len(names) != 1 || names[0] != "meta.json" {
		t.Fatalf("an ended club keeps %v, want only meta.json", names)
	}
}

func TestTakedownAndDisable(t *testing.T) {
	s, c, d := open(t), newClub(1), newClub(2)
	made(t, s, c)
	made(t, s, d)
	for _, x := range []club{c, d} {
		if _, err := s.Post(x.id, x.post, sealed(links.PartPacket, 64, "p"), t0); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.Disable(c.id, t0); err != nil {
		t.Fatal(err)
	}
	if err := s.Check(c.id, Read, c.read, t0); !errors.Is(err, ErrGone) {
		t.Errorf("disabled, member: %v, want ErrGone", err)
	}
	if err := s.Check(c.id, Read, d.read, t0); !errors.Is(err, ErrNotFound) {
		t.Errorf("disabled, stranger: %v, want ErrNotFound", err)
	}
	// Disabling keeps the content for a hold to be made by hand.
	if got := s.contentBytes(c.id); got == 0 {
		t.Errorf("a disabled club lost its content")
	}
	if err := s.Takedown(d.id, t0); err != nil {
		t.Fatal(err)
	}
	if err := s.Check(d.id, Post, d.post, t0); !errors.Is(err, ErrGone) {
		t.Errorf("taken down, member: %v, want ErrGone", err)
	}
	assertOnlyTombstone(t, s, d.id)
	if err := s.Takedown(newClub(30).id, t0); !errors.Is(err, ErrNotFound) {
		t.Errorf("takedown of no club: %v, want ErrNotFound", err)
	}
	if err := s.Takedown("../x", t0); !errors.Is(err, ErrNotFound) {
		t.Errorf("takedown of a bad id: %v, want ErrNotFound", err)
	}
	// A disabled club's content is deleted when its own lifetime ends.
	if n, err := s.Sweep(t0.AddDate(0, 0, 100)); err != nil || n != 1 {
		t.Fatalf("sweep: %d %v, want the disabled club ended", n, err)
	}
	assertOnlyTombstone(t, s, c.id)
}

// Each fact the server holds is declared here. A new field in meta.json, or a new file in a club's folder
// (a name, an address, a sender, a time finer than a day), fails this and has to be argued for.
func TestClubFolderHoldsExactlyTheDeclaredFiles(t *testing.T) {
	s, c := open(t), newClub(1)
	made(t, s, c)
	for i := 0; i < 2; i++ {
		if _, err := s.Post(c.id, c.post, sealed(links.PartPacket, 64, "p"), t0); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := s.List(c.id, c.read, 0, t0.AddDate(0, 0, 2)); err != nil {
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
	want := []string{"<id>/", "<id>/header", "<id>/meta.json", "<id>/posts/", "<id>/posts/1", "<id>/posts/2"}
	if strings.Join(files, " ") != strings.Join(want, " ") {
		t.Fatalf("the clubs folder holds %v, want exactly %v", files, want)
	}
	raw, err := os.ReadFile(s.path(c.id, "meta.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]any
	if err := json.Unmarshal(raw, &fields); err != nil {
		t.Fatal(err)
	}
	var names []string
	for n := range fields {
		names = append(names, n)
	}
	sort.Strings(names)
	if got, want := strings.Join(names, ","), "createdDay,lastActiveDay,postHash,readHash"; got != want {
		t.Fatalf("meta.json fields %s, want exactly %s:\n%s", got, want, raw)
	}
	for _, n := range []string{"createdDay", "lastActiveDay"} {
		if v := fields[n].(string); len(v) != len("2006-01-02") {
			t.Errorf("%s = %q, want a plain day", n, v)
		}
	}
	if fields["lastActiveDay"] != "2026-11-14" {
		t.Errorf("lastActiveDay = %v, want the day of the read, 2026-11-14", fields["lastActiveDay"])
	}
	// Nothing in the folder holds a key, a proof or a raw address: only hashes of proofs.
	for _, p := range []string{c.read, c.post} {
		if bytes.Contains(raw, []byte(p)) {
			t.Errorf("meta.json holds a proof")
		}
	}
	// A tombstone keeps only the same declared fields, with its state.
	if err := s.Takedown(c.id, t0); err != nil {
		t.Fatal(err)
	}
	raw, _ = os.ReadFile(s.path(c.id, "meta.json"))
	json.Unmarshal(raw, &fields)
	names = nil
	for n := range fields {
		names = append(names, n)
	}
	sort.Strings(names)
	if got, want := strings.Join(names, ","), "createdDay,lastActiveDay,postHash,readHash,state"; got != want {
		t.Fatalf("tombstone fields %s, want exactly %s", got, want)
	}
}

// Every file and folder time is midnight UTC of a day, never the moment of a post or a read, so the file
// system cannot say when in a day anyone used a club (B4 section 2).
func TestEveryFileAndFolderTimeIsMidnight(t *testing.T) {
	s, c := open(t), newClub(1)
	made(t, s, c)
	if _, err := s.Post(c.id, c.post, sealed(links.PartPacket, 64, "p"), t0.AddDate(0, 0, 1)); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Post(c.id, c.post, sealed(links.PartPacket, 64, "p"), t0.AddDate(0, 0, 2)); err != nil {
		t.Fatal(err)
	}
	if _, err := s.List(c.id, c.read, 0, t0.AddDate(0, 0, 3)); err != nil {
		t.Fatal(err)
	}
	if err := s.Disable(c.id, t0.AddDate(0, 0, 4)); err != nil {
		t.Fatal(err)
	}
	d := newClub(2)
	made(t, s, d)
	if err := s.Takedown(d.id, t0.AddDate(0, 0, 5)); err != nil {
		t.Fatal(err)
	}
	checked := 0
	filepath.WalkDir(s.dir, func(p string, e os.DirEntry, err error) error {
		info, err := e.Info() // the clubs folder itself included: making a club changes its time too
		if err != nil {
			t.Fatal(err)
		}
		m := info.ModTime().UTC()
		if m != dayOf(m) {
			t.Errorf("%s has time %s, want midnight UTC", strings.TrimPrefix(p, s.dir), m.Format(time.RFC3339Nano))
		}
		checked++
		return nil
	})
	if checked < 8 {
		t.Fatalf("only %d files and folders checked", checked)
	}
}

func TestReadsAreMarkedOncePerDay(t *testing.T) {
	s, c := open(t), newClub(1)
	made(t, s, c)
	if _, err := s.Post(c.id, c.post, sealed(links.PartPacket, 64, "p"), t0); err != nil {
		t.Fatal(err)
	}
	before, _ := os.Stat(s.path(c.id, "meta.json"))
	for i := 0; i < 5; i++ {
		s.List(c.id, c.read, 0, t0.Add(time.Duration(i)*time.Hour))
	}
	after, _ := os.Stat(s.path(c.id, "meta.json"))
	if !after.ModTime().Equal(before.ModTime()) {
		t.Fatalf("meta.json was rewritten by reads on the same day")
	}
}

func TestSweepClearsOnlyOldTemporaryLeftovers(t *testing.T) {
	s, c := open(t), newClub(1)
	made(t, s, c)
	stale := filepath.Join(s.dir, ".club-interrupted")
	fresh := filepath.Join(s.dir, ".club-active")
	for _, d := range []string{stale, fresh} {
		if err := os.Mkdir(d, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	os.Chtimes(stale, t0.Add(-2*time.Hour), t0.Add(-2*time.Hour))
	os.Chtimes(fresh, t0, t0)
	post := s.path(c.id, ".post-stale")
	os.WriteFile(post, []byte("x"), 0o600)
	os.Chtimes(post, t0.Add(-2*time.Hour), t0.Add(-2*time.Hour))
	if _, err := s.Sweep(t0); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(stale); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("an interrupted create was left behind")
	}
	if _, err := os.Stat(fresh); err != nil {
		t.Errorf("an active create was removed")
	}
	if _, err := os.Stat(post); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("an interrupted post was left behind")
	}
}

func TestParallelPostsGetDistinctNumbersWithNoGaps(t *testing.T) {
	s, c := open(t), newClub(1)
	made(t, s, c)
	var wg sync.WaitGroup
	seqs := make(chan int, 60)
	for i := 0; i < 60; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			seq, err := s.Post(c.id, c.post, sealed(links.PartPacket, 64, string(rune('a'+i%26))), t0)
			if err != nil {
				t.Error(err)
				return
			}
			seqs <- seq
		}(i)
	}
	wg.Wait()
	close(seqs)
	var got []int
	for n := range seqs {
		got = append(got, n)
	}
	sort.Ints(got)
	for i, n := range got {
		if n != i+1 {
			t.Fatalf("numbers %v, want 1..60 with no gap or repeat", got)
		}
	}
}

// A takedown that stopped after its tombstone was written leaves content behind. The next sweep finishes
// it, and a second takedown does not take the bytes off the counter twice.
func TestSweepFinishesAnInterruptedTakedownAndTheCounterStaysTrue(t *testing.T) {
	s, c, d := open(t), newClub(1), newClub(2)
	made(t, s, c)
	made(t, s, d)
	for _, x := range []club{c, d} {
		if _, err := s.Post(x.id, x.post, sealed(links.PartPacket, 500, "p"), t0); err != nil {
			t.Fatal(err)
		}
	}
	// Simulate the crash: the tombstone is there, the content is not yet deleted.
	m, _ := s.readMeta(c.id)
	m.State = stateGone
	if err := s.writeMeta(c.id, m, dayOf(t0)); err != nil {
		t.Fatal(err)
	}
	reopened, err := OpenStore(s.dir)
	if err != nil {
		t.Fatal(err)
	}
	if got := reopened.Total(); got != 64+500 {
		t.Fatalf("a restart counts %d, want only the live club's 564", got)
	}
	if err := reopened.Takedown(c.id, t0); err != nil {
		t.Fatal(err)
	}
	if got := reopened.Total(); got != 64+500 {
		t.Fatalf("a second takedown moved the total to %d, want 564", got)
	}
	assertOnlyTombstone(t, reopened, c.id)
	// Sweep alone finishes it too.
	m, _ = s.readMeta(d.id)
	m.State = stateGone
	s.writeMeta(d.id, m, dayOf(t0))
	if _, err := reopened.Sweep(t0); err != nil {
		t.Fatal(err)
	}
	assertOnlyTombstone(t, reopened, d.id)
}

// Another process (the command line) can take a club down; the sweep counts the folder again, so this
// process's cap follows the disk.
func TestSweepCountsTheFolderAgainAfterAnotherProcessTookAClubDown(t *testing.T) {
	s, c := open(t), newClub(1)
	made(t, s, c)
	if _, err := s.Post(c.id, c.post, sealed(links.PartPacket, 500, "p"), t0); err != nil {
		t.Fatal(err)
	}
	cli, _ := OpenStore(s.dir)
	if err := cli.Takedown(c.id, t0); err != nil {
		t.Fatal(err)
	}
	if s.Total() != 564 {
		t.Fatalf("the running store already knew (%d); the test needs it stale", s.Total())
	}
	if _, err := s.Sweep(t0); err != nil {
		t.Fatal(err)
	}
	if s.Total() != 0 {
		t.Fatalf("total after a sweep %d, want 0", s.Total())
	}
}

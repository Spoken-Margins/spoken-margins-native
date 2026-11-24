package links

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"testing"
	"time"
)

// The opened-token vector (#5275) the phone and the browser make from a link's key and id.
type openedVector struct {
	LinkID, TokenHex, MarkHex, OtherTokenHex string
}

func loadOpenedVector(t *testing.T) openedVector {
	t.Helper()
	data, err := os.ReadFile("../../../contracts/fixtures/share-link-opened-token.json")
	if err != nil {
		t.Fatal(err)
	}
	var v openedVector
	if err := json.Unmarshal(data, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

func openedStore(t *testing.T, now time.Time) (*Store, string) {
	t.Helper()
	s, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	preview, packet, _, _ := loadVector(t)
	id, _, err := s.Put(packet, preview, now)
	if err != nil {
		t.Fatal(err)
	}
	return s, id
}

func metaFields(t *testing.T, s *Store, id string) map[string]json.RawMessage {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(s.dir, id, "meta.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		t.Fatal(err)
	}
	return fields
}

func keysOf(m map[string]json.RawMessage) string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return strings.Join(keys, ",")
}

func TestOpenedMarkIsTheTokenHashAndNothingElse(t *testing.T) {
	v := loadOpenedVector(t)
	made := time.Date(2026, 11, 24, 0, 0, 0, 0, time.UTC)
	s, id := openedStore(t, made)
	opened := made.Add(5*24*time.Hour + 13*time.Hour + 7*time.Minute)
	if err := s.MarkOpened(id, v.TokenHex, opened); err != nil {
		t.Fatal(err)
	}
	fields := metaFields(t, s, id)
	if keysOf(fields) != "expiresAt,openedMarks" {
		t.Fatalf("meta.json holds %s, want only expiresAt and openedMarks", keysOf(fields))
	}
	if string(fields["openedMarks"]) != `["`+v.MarkHex+`"]` {
		t.Fatalf("mark %s, want the vector's sha256(token)", fields["openedMarks"])
	}
	data, _ := os.ReadFile(filepath.Join(s.dir, id, "meta.json"))
	if strings.Contains(string(data), v.TokenHex) || strings.Contains(string(data), "2026-11-29") {
		t.Fatalf("meta.json holds the token or the day it was opened: %s", data)
	}
	// The write is backdated to the link's creation, so neither the file nor its folder dates the open.
	for _, path := range []string{filepath.Join(s.dir, id, "meta.json"), filepath.Join(s.dir, id)} {
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if !info.ModTime().Equal(made) {
			t.Fatalf("%s modified %v, want the creation time %v", path, info.ModTime().UTC(), made)
		}
	}
	// No temporary file is left behind to date it either.
	entries, _ := os.ReadDir(filepath.Join(s.dir, id))
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), ".") {
			t.Fatalf("left %s behind", e.Name())
		}
	}
	if until, err := s.liveUntil(id, opened); err != nil || !until.Equal(made.Add(Lifetime)) {
		t.Fatalf("marking changed the expiry: %v %v", until, err)
	}
}

func TestOpenedNeedsTheSameToken(t *testing.T) {
	v := loadOpenedVector(t)
	now := time.Date(2026, 11, 24, 0, 0, 0, 0, time.UTC)
	s, id := openedStore(t, now)
	if s.IsOpened(id, v.TokenHex, now) {
		t.Fatal("opened before anyone opened it")
	}
	if err := s.MarkOpened(id, v.OtherTokenHex, now); err != nil {
		t.Fatal(err)
	}
	if s.IsOpened(id, v.TokenHex, now) {
		t.Fatal("someone else's token made the real one read opened")
	}
	if err := s.MarkOpened(id, v.TokenHex, now); err != nil {
		t.Fatal(err)
	}
	if !s.IsOpened(id, v.TokenHex, now) {
		t.Fatal("the real token does not read opened")
	}
	for _, bad := range []string{"", v.MarkHex[:63], strings.ToUpper(v.TokenHex), v.TokenHex + "0", strings.Repeat("g", 64)} {
		if s.IsOpened(id, bad, now) {
			t.Fatalf("%q reads opened", bad)
		}
		if err := s.MarkOpened(id, bad, now); err == nil {
			t.Fatalf("%q was accepted as a token", bad)
		}
	}
	// Marking twice keeps one mark.
	if err := s.MarkOpened(id, v.TokenHex, now); err != nil {
		t.Fatal(err)
	}
	if got := string(metaFields(t, s, id)["openedMarks"]); strings.Count(got, v.MarkHex) != 1 {
		t.Fatalf("marks %s", got)
	}
}

func TestOpenedMarksCapped(t *testing.T) {
	v := loadOpenedVector(t)
	now := time.Date(2026, 11, 24, 0, 0, 0, 0, time.UTC)
	s, id := openedStore(t, now)
	for i := 0; i < MaxOpenedMarks; i++ {
		junk := strings.Repeat(string("0123456789abcdef"[i]), 64)
		if err := s.MarkOpened(id, junk, now); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.MarkOpened(id, v.TokenHex, now); err != nil {
		t.Fatal(err)
	}
	if s.IsOpened(id, v.TokenHex, now) {
		t.Fatal("a ninth mark was kept")
	}
	var marks []string
	json.Unmarshal(metaFields(t, s, id)["openedMarks"], &marks)
	if len(marks) != MaxOpenedMarks {
		t.Fatalf("%d marks, want %d", len(marks), MaxOpenedMarks)
	}
}

func TestOpenedOnlyWhileServed(t *testing.T) {
	v := loadOpenedVector(t)
	now := time.Date(2026, 11, 24, 0, 0, 0, 0, time.UTC)
	s, id := openedStore(t, now)
	if err := s.MarkOpened(id, v.TokenHex, now); err != nil {
		t.Fatal(err)
	}
	// Disable keeps the content for a hold, and drops the mark.
	if err := s.Disable(id, now); err != nil {
		t.Fatal(err)
	}
	if s.IsOpened(id, v.TokenHex, now) {
		t.Fatal("a disabled link reads opened")
	}
	if _, ok := metaFields(t, s, id)["openedMarks"]; ok {
		t.Fatal("Disable kept the mark")
	}
	if err := s.MarkOpened(id, v.TokenHex, now); err == nil {
		t.Fatal("a disabled link took a mark")
	}
	// Takedown writes a fresh tombstone.
	s2, id2 := openedStore(t, now)
	s2.MarkOpened(id2, v.TokenHex, now)
	if err := s2.Takedown(id2); err != nil {
		t.Fatal(err)
	}
	if s2.IsOpened(id2, v.TokenHex, now) || keysOf(metaFields(t, s2, id2)) != "expiresAt" {
		t.Fatal("a taken-down link kept its mark")
	}
	if err := s2.MarkOpened("0123456789abcdef0123456789abcdef", v.TokenHex, now); err == nil {
		t.Fatal("an unknown link took a mark")
	}
}

func TestSweepDropsOpenedMarksAndRewritesLiveMeta(t *testing.T) {
	v := loadOpenedVector(t)
	made := time.Date(2026, 11, 24, 0, 0, 0, 0, time.UTC)
	s, expiring := openedStore(t, made)
	preview, packet, _, _ := loadVector(t)
	live, _, err := s.Put(packet, preview, made.Add(20*24*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{expiring, live} {
		if err := s.MarkOpened(id, v.TokenHex, made.Add(21*24*time.Hour)); err != nil {
			t.Fatal(err)
		}
	}
	before, _ := os.ReadFile(filepath.Join(s.dir, live, "meta.json"))
	// Take the live link's meta.json off its creation time; the sweep must set it back.
	os.Chtimes(filepath.Join(s.dir, live, "meta.json"), made.Add(29*24*time.Hour), made.Add(29*24*time.Hour))
	beforeInode := inode(t, filepath.Join(s.dir, live, "meta.json"))
	sweep := made.Add(Lifetime + time.Hour)
	if _, err := s.Sweep(sweep); err != nil {
		t.Fatal(err)
	}
	if keysOf(metaFields(t, s, expiring)) != "expiresAt" {
		t.Fatalf("expired link kept %s", keysOf(metaFields(t, s, expiring)))
	}
	after, _ := os.ReadFile(filepath.Join(s.dir, live, "meta.json"))
	if string(after) != string(before) {
		t.Fatalf("the sweep changed a live link's meta.json: %s -> %s", before, after)
	}
	if inode(t, filepath.Join(s.dir, live, "meta.json")) == beforeInode {
		t.Fatal("the sweep did not write the live link's meta.json again")
	}
	info, _ := os.Stat(filepath.Join(s.dir, live, "meta.json"))
	if want := made.Add(20 * 24 * time.Hour); !info.ModTime().Equal(want) {
		t.Fatalf("live meta.json modified %v, want its creation %v", info.ModTime().UTC(), want)
	}
	if !s.IsOpened(live, v.TokenHex, sweep) {
		t.Fatal("the sweep dropped a live link's mark")
	}
}

// inode tells a rewritten file from one left alone: writeMetaLocked replaces meta.json by renaming a new file.
func inode(t *testing.T, path string) uint64 {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	return uint64(info.Sys().(*syscall.Stat_t).Ino)
}

// One live link whose meta.json can't be rewritten must not stop the sweep deleting another link's expired content.
func TestSweepGoesOnPastALinkItCannotRewrite(t *testing.T) {
	made := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	s, expired := openedStore(t, made)
	preview, packet, _, _ := loadVector(t)
	stuck, _, err := s.Put(packet, preview, made.Add(20*24*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	stuckDir := filepath.Join(s.dir, stuck)
	if err := os.Chmod(stuckDir, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(stuckDir, 0o700) })
	if _, err := os.CreateTemp(stuckDir, ".probe-"); err == nil {
		t.Skip("this user can write a read-only folder (root?)")
	}
	n, err := s.Sweep(made.Add(Lifetime + time.Hour))
	if err != nil || n != 1 {
		t.Fatalf("sweep: %d %v, want 1 deleted and no error", n, err)
	}
	if _, err := os.Stat(filepath.Join(s.dir, expired, "packet")); !os.IsNotExist(err) {
		t.Fatal("the expired link's packet outlived its 30 days")
	}
}

// A CLI takedown writes its tombstone and then deletes the content. A mark that lands between the two (it rewrites
// the live metadata it read) must not make the link read opened or take a mark once the content is gone.
func TestNoMarkOnceTheContentIsGone(t *testing.T) {
	v := loadOpenedVector(t)
	now := time.Date(2026, 11, 24, 0, 0, 0, 0, time.UTC)
	s, id := openedStore(t, now)
	if err := s.MarkOpened(id, v.TokenHex, now); err != nil {
		t.Fatal(err)
	}
	if err := s.deleteContent(id); err != nil {
		t.Fatal(err)
	}
	if s.IsOpened(id, v.TokenHex, now) {
		t.Fatal("a link with no content reads opened")
	}
	if err := s.MarkOpened(id, v.OtherTokenHex, now); err == nil {
		t.Fatal("a link with no content took a mark")
	}
}

package links

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func previewJSON(t *testing.T, edit func(map[string]any)) []byte {
	t.Helper()
	p := map[string]any{
		"schema": PreviewSchema,
		"source": map[string]any{"title": "The Long Walk", "show": "Field Notes", "url": "https://example.com/episodes/long-walk"},
		"margins": []map[string]any{
			{"text": "This is where it turns.", "before": "and then the river", "after": "rose over the bank"},
		},
	}
	if edit != nil {
		edit(p)
	}
	data, err := json.Marshal(p)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func firstMargin(p map[string]any) map[string]any { return p["margins"].([]map[string]any)[0] }

func TestParsePreviewChecks(t *testing.T) {
	if _, err := ParsePreview(previewJSON(t, nil)); err != nil {
		t.Fatalf("good preview refused: %v", err)
	}
	// 500 characters a side is allowed, counted as characters, not bytes.
	exactly := strings.Repeat("é", MaxExcerptChars)
	if _, err := ParsePreview(previewJSON(t, func(p map[string]any) {
		firstMargin(p)["before"], firstMargin(p)["after"] = exactly, exactly
	})); err != nil {
		t.Fatalf("500-character excerpts refused: %v", err)
	}

	over := strings.Repeat("a", MaxExcerptChars+1)
	bad := map[string]func(map[string]any){
		"before over 500":  func(p map[string]any) { firstMargin(p)["before"] = over },
		"after over 500":   func(p map[string]any) { firstMargin(p)["after"] = over },
		"wrong schema":     func(p map[string]any) { p["schema"] = "spokenmargins.link-preview.v0" },
		"no Margins":       func(p map[string]any) { p["margins"] = []map[string]any{} },
		"no source title":  func(p map[string]any) { p["source"].(map[string]any)["title"] = "  " },
		"unknown field":    func(p map[string]any) { p["audio"] = "https://example.com/a.mp3" },
		"title over 300":   func(p map[string]any) { p["source"].(map[string]any)["title"] = strings.Repeat("t", 301) },
		"over 16 KB total": func(p map[string]any) { firstMargin(p)["text"] = strings.Repeat("x", MaxPreviewBytes) },
	}
	for name, edit := range bad {
		if _, err := ParsePreview(previewJSON(t, edit)); !errors.Is(err, ErrBadPreview) {
			t.Errorf("%s: got %v, want ErrBadPreview", name, err)
		}
	}
}

func TestPublicSourceURL(t *testing.T) {
	for raw, want := range map[string]string{
		"https://example.com/episodes/long-walk": "https://example.com/episodes/long-walk",
		"http://example.com/a":                   "http://example.com/a",
		"https://medium.com/@writer/a-post":      "https://medium.com/@writer/a-post",
		"https://example.com/feed?token=s3cret":  "",
		"https://example.com/a?":                 "",
		"https://example.com/a#t=10":             "",
		"https://user:pw@example.com/a":          "",
		"https://user@example.com/a":             "",
		"javascript:alert(1)":                    "",
		"file:///etc/passwd":                     "",
		"/relative/path":                         "",
		"":                                       "",
	} {
		if got := PublicSourceURL(raw); got != want {
			t.Errorf("PublicSourceURL(%q) = %q, want %q", raw, got, want)
		}
	}
	// ParsePreview drops a token-carrying URL before anything is stored.
	p, err := ParsePreview(previewJSON(t, func(p map[string]any) {
		p["source"].(map[string]any)["url"] = "https://feeds.example.com/private?token=s3cret"
	}))
	if err != nil || p.Source.URL != "" {
		t.Fatalf("token URL kept: %q, %v", p.Source.URL, err)
	}
}

func packet(n int) []byte {
	b := bytes.Repeat([]byte{0x5a}, n)
	copy(b, zipMagic)
	return b
}

func goodPreview(t *testing.T) Preview {
	p, err := ParsePreview(previewJSON(t, nil))
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func files(t *testing.T, dir string) []string {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, e := range entries {
		names = append(names, e.Name())
	}
	return names
}

func TestIDsAreUnguessable(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 1000; i++ {
		id, err := NewID()
		if err != nil {
			t.Fatal(err)
		}
		if !ValidID(id) || seen[id] {
			t.Fatalf("bad or repeated id %q", id)
		}
		seen[id] = true
	}
	if idBytes*8 < 128 {
		t.Fatalf("ids carry %d random bits, want at least 128", idBytes*8)
	}
	for _, id := range []string{"", "short", "../../etc/passwd", strings.Repeat("a", 31) + "/", strings.Repeat("a", 33), strings.Repeat("A", 32), "-" + strings.Repeat("a", 31)} {
		if ValidID(id) {
			t.Errorf("ValidID(%q) = true", id)
		}
	}
}

func TestCreateKeepsThePacketByteForByte(t *testing.T) {
	dir := t.TempDir()
	s, err := OpenStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	data := packet(3 << 20)
	id, err := s.Create(bytes.NewReader(data), goodPreview(t), now)
	if err != nil {
		t.Fatal(err)
	}
	l, err := s.Get(id, now)
	if err != nil || l.Preview.Margins[0].Text != "This is where it turns." {
		t.Fatalf("Get: %+v, %v", l, err)
	}
	f, err := s.OpenPacket(id, now)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	got, _ := io.ReadAll(f)
	if sha256.Sum256(got) != sha256.Sum256(data) {
		t.Fatal("packet changed on the way through the store")
	}
}

func TestCreateRefusals(t *testing.T) {
	dir := t.TempDir()
	s, _ := OpenStore(dir)
	now := time.Now()
	if _, err := s.Create(bytes.NewReader(packet(MaxPacketBytes+1)), goodPreview(t), now); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("over 20 MB: got %v", err)
	}
	if _, err := s.Create(strings.NewReader("<html>not a packet</html>"), goodPreview(t), now); !errors.Is(err, ErrBadPacket) {
		t.Fatalf("not a ZIP: got %v", err)
	}
	if left := files(t, dir); len(left) != 0 {
		t.Fatalf("refused uploads left files behind: %v", left)
	}
	// Exactly 20 MB is allowed.
	if _, err := s.Create(bytes.NewReader(packet(MaxPacketBytes)), goodPreview(t), now); err != nil {
		t.Fatalf("20 MB refused: %v", err)
	}

	full, _ := OpenStore(t.TempDir())
	full.MaxBytes = 5 << 20
	if _, err := full.Create(bytes.NewReader(packet(3<<20)), goodPreview(t), now); err != nil {
		t.Fatal(err)
	}
	if _, err := full.Create(bytes.NewReader(packet(3<<20)), goodPreview(t), now); !errors.Is(err, ErrFull) {
		t.Fatalf("past the size cap: got %v", err)
	}
}

func TestLinksExpireAndTheSweepDeletesThem(t *testing.T) {
	dir := t.TempDir()
	s, _ := OpenStore(dir)
	made := time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC)
	old, _ := s.Create(bytes.NewReader(packet(100)), goodPreview(t), made)
	fresh, _ := s.Create(bytes.NewReader(packet(100)), goodPreview(t), made.Add(10*24*time.Hour))

	day29 := made.Add(Lifetime - time.Second)
	if _, err := s.Get(old, day29); err != nil {
		t.Fatalf("link gone before 30 days: %v", err)
	}
	day30 := made.Add(Lifetime)
	if _, err := s.Get(old, day30); !errors.Is(err, ErrExpired) {
		t.Fatalf("at 30 days: got %v, want ErrExpired", err)
	}
	if _, err := s.OpenPacket(old, day30); !errors.Is(err, ErrExpired) {
		t.Fatalf("expired packet: got %v", err)
	}

	n, err := s.Sweep(day30)
	if err != nil || n != 2 {
		t.Fatalf("sweep deleted %d files (%v), want the expired record and packet", n, err)
	}
	if _, err := s.Get(old, day30); !errors.Is(err, ErrNotFound) {
		t.Fatalf("after the sweep: got %v", err)
	}
	if _, err := s.Get(fresh, day30); err != nil {
		t.Fatalf("sweep took a live link: %v", err)
	}
	want := []string{fresh + ".json", fresh + ".packet"}
	if got := files(t, dir); strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("files after sweep %v, want %v", got, want)
	}
}

func TestSweepClearsOrphansButNotUploadsInProgress(t *testing.T) {
	dir := t.TempDir()
	s, _ := OpenStore(dir)
	id, _ := NewID()
	orphan := filepath.Join(dir, id+".packet")
	tmp := filepath.Join(dir, ".tmp-123")
	os.WriteFile(orphan, packet(10), 0o600)
	os.WriteFile(tmp, packet(10), 0o600)

	now := time.Now()
	if n, _ := s.Sweep(now); n != 0 {
		t.Fatalf("swept %d files under an hour old", n)
	}
	if n, _ := s.Sweep(now.Add(2 * time.Hour)); n != 2 {
		t.Fatalf("swept %d, want the orphan packet and the temporary file", n)
	}
}

func TestTakedown(t *testing.T) {
	dir := t.TempDir()
	s, _ := OpenStore(dir)
	now := time.Now()
	id, _ := s.Create(bytes.NewReader(packet(100)), goodPreview(t), now)
	if deleted, err := s.Takedown(id); err != nil || !deleted {
		t.Fatalf("takedown: %v %v", deleted, err)
	}
	if _, err := s.Get(id, now); !errors.Is(err, ErrNotFound) {
		t.Fatalf("after takedown: %v", err)
	}
	if left := files(t, dir); len(left) != 0 {
		t.Fatalf("takedown left %v", left)
	}
	if deleted, err := s.Takedown(id); err != nil || deleted {
		t.Fatalf("second takedown: %v %v", deleted, err)
	}
	if _, err := s.Takedown("../escape"); err == nil {
		t.Fatal("takedown accepted a path")
	}
}

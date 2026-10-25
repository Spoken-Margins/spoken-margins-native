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

const fixture = `{"source":{"title":"A source <title>","show":"A show & name","url":"https://example.org/episode"},"margins":[{"text":"My <script>alert(1)</script>","before":"Before <img src=x>","after":"After & <b>text</b>"},{"text":"Second Margin","before":"second before","after":"second after"}]}`
const install = "https://testflight.apple.com/join/fixture"

func TestLinkPreviewValidation(t *testing.T) {
	// Neighbouring values: ASCII, Unicode, whitespace, punctuation, empty,
	// normalization variants, and a very long excerpt on either side. The sides
	// have different caps (#2237): 500 before the Margin, 120 after it.
	for _, side := range []struct {
		name string
		max  int
	}{{"before", MaxBeforeCharacters}, {"after", MaxAfterCharacters}} {
		for _, row := range []struct {
			name, text string
			valid      bool
		}{
			{"empty", "", true}, {"whitespace", " \t\n", true}, {"punctuation", "—.!?", true},
			{"case", "Aa", true}, {"at the cap, ASCII", strings.Repeat("x", side.max), true},
			{"at the cap, Unicode", strings.Repeat("🎧", side.max), true}, {"composed", "café", true},
			{"decomposed", "cafe\u0301", true}, {"over the cap, ASCII", strings.Repeat("x", side.max+1), false},
			{"over the cap, Unicode", strings.Repeat("🎧", side.max+1), false}, {"very long", strings.Repeat("x", 16000), false},
		} {
			t.Run(side.name+"/"+row.name, func(t *testing.T) {
				p, _ := ParsePreview([]byte(fixture))
				if side.name == "before" {
					p.Margins[0].Before = row.text
				} else {
					p.Margins[0].After = row.text
				}
				data, _ := json.Marshal(p)
				_, err := ParsePreview(data)
				if (err == nil) != row.valid {
					t.Fatalf("valid=%v, err=%v", row.valid, err)
				}
			})
		}
	}
	// The caps are not the same on both sides: 121 characters fit before a Margin, not after it.
	p, _ := ParsePreview([]byte(fixture))
	p.Margins[0].Before = strings.Repeat("x", MaxAfterCharacters+1)
	p.Margins[0].After = strings.Repeat("x", MaxAfterCharacters+1)
	data, _ := json.Marshal(p)
	if _, err := ParsePreview(data); err == nil {
		t.Fatal("an after excerpt of 121 characters was accepted")
	}
	p.Margins[0].After = ""
	data, _ = json.Marshal(p)
	if _, err := ParsePreview(data); err != nil {
		t.Fatalf("a before excerpt of 121 characters was refused: %v", err)
	}
	for _, data := range [][]byte{[]byte(`{}`), []byte(`null`), []byte(fixture + ` {}`), []byte(strings.Replace(fixture, `"source":`, `"unknown":true,"source":`, 1)), bytes.Repeat([]byte(" "), MaxPreviewBytes+1), {0xff}} {
		if _, err := ParsePreview(data); err == nil {
			t.Fatalf("accepted bad preview: %.50s", data)
		}
	}
}

func TestLinkLandingEscapesFixtureAndOmitsUnsafeURLs(t *testing.T) {
	p, err := ParsePreview([]byte(fixture))
	if err != nil {
		t.Fatal(err)
	}
	for _, row := range []struct {
		url  string
		safe bool
	}{
		{"https://example.org/episode", true}, {"http://example.org/a", true},
		{"HTTPS://example.org/A", true}, {"https://other.example/episode", true},
		{"https://examp1e.org/episode", true}, {"https://example.org/caf%C3%A9", true},
		{"https://example.org/episode?token=PRIVATE", false}, {"https://example.org/episode?", false},
		{"https://PRIVATE:secret@example.org/episode", false}, {"https://example.org/episode#PRIVATE", false},
		{"javascript:alert(1)", false}, {"//example.org/a", false}, {"", false}, {" https://example.org/a", false},
		{"https://example.org/\nPRIVATE", false}, {"https://", false}, {"https://example.org/%zz", false},
	} {
		t.Run(row.url, func(t *testing.T) {
			p.Source.URL = row.url
			var page bytes.Buffer
			if err := Render(&page, strings.Repeat("a", 32), p, install); err != nil {
				t.Fatal(err)
			}
			html := page.String()
			if strings.Contains(html, "<audio") || strings.Contains(html, "<script>") || strings.Contains(html, "<img src=x>") || strings.Contains(html, "<b>text</b>") {
				t.Fatal("unescaped HTML or audio")
			}
			if !strings.Contains(html, "&lt;script&gt;") || !strings.Contains(html, "&lt;img src=x&gt;") || !strings.Contains(html, "&lt;b&gt;text&lt;/b&gt;") {
				t.Fatal("escaped fixture missing")
			}
			if strings.Contains(html, "Open public source") != row.safe {
				t.Fatalf("safe=%v, page %s", row.safe, html)
			}
			if !row.safe && (strings.Contains(html, "PRIVATE") || (row.url != "" && strings.Contains(html, `href="`+row.url+`"`))) {
				t.Fatal("unsafe source URL leaked")
			}
			for _, want := range []string{"A source &lt;title&gt;", "A show &amp; name", "Quotation from the source", "Second Margin", "second before", "second after", "Report this link", install} {
				if !strings.Contains(html, want) {
					t.Errorf("missing %q", want)
				}
			}
		})
	}
}

func TestLinkStoreRoundTripExpiryAndSweep(t *testing.T) {
	dir := t.TempDir()
	st, err := OpenStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)
	packet := []byte{'P', 'K', 0, 255, 1, 2, 3}
	id, expiry, err := st.Put(packet, []byte(fixture), now)
	if err != nil {
		t.Fatal(err)
	}
	if !ValidID(id) || !expiry.Equal(now.Add(Lifetime)) {
		t.Fatalf("id=%q expiry=%s", id, expiry)
	}
	other, _, err := st.Put(packet, []byte(fixture), now)
	if err != nil || other == id {
		t.Fatal("ids not independently random")
	}
	// A new process/store sees the exact same file, not an in-memory fake.
	reopened, _ := OpenStore(dir)
	f, err := reopened.Packet(id, expiry.Add(-time.Nanosecond))
	if err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(f)
	f.Close()
	if err != nil || sha256.Sum256(got) != sha256.Sum256(packet) {
		t.Fatal("packet bytes changed")
	}
	if _, err := reopened.Preview(id, expiry); !errors.Is(err, ErrGone) {
		t.Fatalf("at expiry: %v", err)
	}
	if _, err := reopened.Packet(id, expiry); !errors.Is(err, ErrGone) {
		t.Fatalf("expired packet: %v", err)
	}
	if n, err := reopened.Sweep(expiry.Add(-time.Nanosecond)); err != nil || n != 0 {
		t.Fatalf("early sweep %d %v", n, err)
	}
	if n, err := reopened.Sweep(expiry); err != nil || n != 2 {
		t.Fatalf("sweep %d %v", n, err)
	}
	for _, name := range []string{"packet", "preview.json"} {
		if _, err := os.Stat(filepath.Join(dir, id, name)); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("content still stored: %s %v", name, err)
		}
	}
	if _, err := reopened.Packet(id, expiry.Add(time.Hour)); !errors.Is(err, ErrGone) {
		t.Fatal("sweep lost the 410 marker")
	}
	if _, err := reopened.Preview(strings.Repeat("0", 32), now); !errors.Is(err, ErrNotFound) {
		t.Fatal("unknown id")
	}
	if n, err := reopened.Sweep(expiry.Add(time.Hour)); err != nil || n != 0 {
		t.Fatalf("repeat sweep %d %v", n, err)
	}
}

func TestLinkStoreBoundsAndTakedown(t *testing.T) {
	dir := t.TempDir()
	st, _ := OpenStore(dir)
	now := time.Now()
	if _, _, err := st.Put(make([]byte, MaxPacketBytes+1), []byte(fixture), now); !errors.Is(err, ErrTooLarge) {
		t.Fatal("oversize packet accepted")
	}
	id, _, err := st.Put([]byte("packet"), []byte(fixture), now)
	if err != nil {
		t.Fatal(err)
	}
	admin, _ := OpenStore(dir)
	if err := admin.Takedown(id); err != nil {
		t.Fatal(err)
	}
	if _, err := st.Packet(id, now); !errors.Is(err, ErrGone) {
		t.Fatal("takedown not immediate")
	}
	if _, err := st.Preview(id, now); !errors.Is(err, ErrGone) {
		t.Fatal("takedown kept preview")
	}
	if err := admin.Takedown(id); err != nil {
		t.Fatal("takedown not idempotent")
	}
	for _, name := range []string{"packet", "preview.json"} {
		if _, err := os.Stat(filepath.Join(dir, id, name)); !errors.Is(err, os.ErrNotExist) {
			t.Fatal("takedown left content")
		}
	}
	for _, bad := range []string{"../", "", strings.Repeat("A", 32), id + "/packet"} {
		if _, err := st.Packet(bad, now); !errors.Is(err, ErrNotFound) {
			t.Fatal("invalid id accepted")
		}
		if err := admin.Takedown(bad); !errors.Is(err, ErrNotFound) {
			t.Fatal("invalid takedown id accepted")
		}
	}
}

func TestLinkStoreFilesArePrivateAndFailedUploadIsUnpublished(t *testing.T) {
	dir := t.TempDir()
	st, err := OpenStore(filepath.Join(dir, "links"))
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := st.Put([]byte("packet"), []byte(`{}`), time.Now()); err == nil {
		t.Fatal("invalid preview stored")
	}
	entries, err := os.ReadDir(st.dir)
	if err != nil || len(entries) != 0 {
		t.Fatal("failed upload left files")
	}
	id, _, err := st.Put([]byte("packet"), []byte(fixture), time.Now())
	if err != nil {
		t.Fatal(err)
	}
	for _, rel := range []string{"", id, id + "/packet", id + "/preview.json", id + "/meta.json"} {
		info, err := os.Stat(filepath.Join(st.dir, rel))
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm()&0o077 != 0 {
			t.Fatalf("public share data file %s mode %s", rel, info.Mode())
		}
	}
}

func TestLinkInstallURLValidation(t *testing.T) {
	for _, row := range []struct {
		url   string
		valid bool
	}{
		{install, true}, {"https://apps.apple.com/us/app/spoken-margins/id123456789", true},
		{"https://testflight.apple.com/", false}, {"https://testflight.apple.com/join/", false},
		{"https://testflight.apple.com.evil.test/join/code", false}, {"https://testflight.apple.com@evil.test/join/code", false},
		{"https://testflight.apple.com/join/code?token=secret", false}, {"http://testflight.apple.com/join/code", false}, {"", false},
	} {
		if ValidInstallURL(row.url) != row.valid {
			t.Errorf("%s valid=%v", row.url, row.valid)
		}
	}
}

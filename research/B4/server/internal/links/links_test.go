package links

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const install = "https://testflight.apple.com/join/fixture"

// The vector the phone (ShareLinkSealingTests) and the browser (share-link-open.test.mjs) check
// against (#805): the server must store and serve these bytes without reading them.
type sealingVector struct {
	KeyFragment string `json:"keyFragment"`
	Preview     struct {
		Plaintext string `json:"plaintextBase64"`
		Sealed    string `json:"sealedBase64"`
	} `json:"preview"`
	Packet struct {
		Plaintext string `json:"plaintextBase64"`
		Sealed    string `json:"sealedBase64"`
	} `json:"packet"`
}

func loadVector(t *testing.T) (preview, packet, previewPlain, packetPlain []byte) {
	t.Helper()
	data, err := os.ReadFile("../../../contracts/fixtures/share-link-sealing-vector.json")
	if err != nil {
		t.Fatal(err)
	}
	var v sealingVector
	if err := json.Unmarshal(data, &v); err != nil {
		t.Fatal(err)
	}
	decode := func(s string) []byte {
		b, err := base64.StdEncoding.DecodeString(s)
		if err != nil || len(b) == 0 {
			t.Fatalf("vector: %v", err)
		}
		return b
	}
	return decode(v.Preview.Sealed), decode(v.Packet.Sealed), decode(v.Preview.Plaintext), decode(v.Packet.Plaintext)
}

func TestSealedPartsAreRecognisedByHeaderAndLength(t *testing.T) {
	preview, packet, previewPlain, packetPlain := loadVector(t)
	if !Sealed(preview, PartPreview) || !Sealed(packet, PartPacket) {
		t.Fatal("the shared vector's sealed parts were refused")
	}
	minimal := append([]byte("SMLINK\x01\x01"), make([]byte, nonceBytes+tagBytes)...)
	for _, row := range []struct {
		name string
		data []byte
		part byte
		want bool
	}{
		{"packet as the preview", packet, PartPreview, false},
		{"preview as the packet", preview, PartPacket, false},
		{"readable preview JSON", previewPlain, PartPreview, false},
		{"readable packet zip", packetPlain, PartPacket, false},
		{"empty", nil, PartPreview, false},
		{"header only", preview[:8], PartPreview, false},
		{"one byte short of header, nonce and tag", minimal[:SealedOverhead-1], PartPreview, false},
		{"header, nonce and tag with no ciphertext", minimal, PartPreview, true},
		{"version 2", append([]byte("SMLINK\x02\x01"), preview[8:]...), PartPreview, false},
		{"lower-case magic", append([]byte("smlink\x01\x01"), preview[8:]...), PartPreview, false},
		{"part 3", append([]byte("SMLINK\x01\x03"), preview[8:]...), PartPreview, false},
	} {
		if got := Sealed(row.data, row.part); got != row.want {
			t.Errorf("%s: sealed=%v, want %v", row.name, got, row.want)
		}
	}
}

func TestLinkLandingIsAShellWithNoPreview(t *testing.T) {
	id := strings.Repeat("a", 32)
	var page bytes.Buffer
	if err := Render(&page, id, install); err != nil {
		t.Fatal(err)
	}
	html := page.String()
	for _, want := range []string{
		`<script type="module" src="/l/share-link-page.mjs"></script>`,
		`<section id="margins" data-link="` + id + `"><p id="status" role="status"></p>`,
		`<noscript>`, `action="/l/` + id + `/report"`, "Report this link", `name="category"`, `name="link"`, install,
	} {
		if !strings.Contains(html, want) {
			t.Errorf("missing %q", want)
		}
	}
	if strings.Contains(html, "<audio") {
		t.Fatal("audio on the page")
	}
	for _, bad := range [][2]string{{"../", install}, {strings.Repeat("A", 32), install}, {id, "https://evil.test/join/x"}} {
		if err := Render(io.Discard, bad[0], bad[1]); err == nil {
			t.Errorf("rendered with %q %q", bad[0], bad[1])
		}
	}
}

func TestLinkPageScriptsAreTheEmbeddedModules(t *testing.T) {
	for _, name := range []string{"share-link-open.mjs", "share-link-page.mjs"} {
		got, ok := PageScript(name)
		want, err := os.ReadFile(name)
		if !ok || err != nil || !bytes.Equal(got, want) {
			t.Fatalf("%s: not the file on disk", name)
		}
	}
	for _, name := range []string{"", "share-link-open.test.mjs", "sealed.go", "../links/sealed.go", "share-link-page.mjs/"} {
		if _, ok := PageScript(name); ok {
			t.Errorf("served %q", name)
		}
	}
}

func TestLinkStoreRoundTripExpiryAndSweep(t *testing.T) {
	dir := t.TempDir()
	st, err := OpenStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)
	preview, packet, previewPlain, packetPlain := loadVector(t)
	id, expiry, err := st.Put(packet, preview, now)
	if err != nil {
		t.Fatal(err)
	}
	if !ValidID(id) || !expiry.Equal(now.Add(Lifetime)) {
		t.Fatalf("id=%q expiry=%s", id, expiry)
	}
	other, _, err := st.Put(packet, preview, now)
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
	gotPreview, err := reopened.Preview(id, expiry.Add(-time.Nanosecond))
	if err != nil || !bytes.Equal(gotPreview, preview) {
		t.Fatal("sealed preview bytes changed")
	}
	if err := reopened.Live(id, expiry.Add(-time.Nanosecond)); err != nil {
		t.Fatal(err)
	}
	// Nothing readable is on disk: neither the Margin's text and title nor the packet's plaintext.
	filepath.WalkDir(dir, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		data, _ := os.ReadFile(path)
		for _, plain := range [][]byte{[]byte("This is the part I wanted you to hear"), []byte("Fourier"), previewPlain, packetPlain[:32]} {
			if bytes.Contains(data, plain) {
				t.Fatalf("%s holds readable %q", path, plain)
			}
		}
		return nil
	})
	if _, err := reopened.Preview(id, expiry); !errors.Is(err, ErrGone) {
		t.Fatalf("at expiry: %v", err)
	}
	if err := reopened.Live(id, expiry); !errors.Is(err, ErrGone) {
		t.Fatalf("live at expiry: %v", err)
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
	for _, name := range contentFiles {
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
	preview, packet, previewPlain, packetPlain := loadVector(t)
	big := append(append([]byte{}, packet[:8]...), make([]byte, MaxPacketBytes-8+1)...)
	if _, _, err := st.Put(big, preview, now); !errors.Is(err, ErrTooLarge) {
		t.Fatal("oversize packet accepted")
	}
	bigPreview := append(append([]byte{}, preview[:8]...), make([]byte, MaxPreviewBytes-8+1)...)
	if _, _, err := st.Put(packet, bigPreview, now); !errors.Is(err, ErrTooLarge) {
		t.Fatal("oversize preview accepted")
	}
	if _, _, err := st.Put(packet, bigPreview[:MaxPreviewBytes], now); err != nil {
		t.Fatalf("a sealed preview of exactly 16 KB was refused: %v", err)
	}
	for _, row := range [][2][]byte{{packet, previewPlain}, {packetPlain, preview}, {preview, packet}, {packet, packet}} {
		if _, _, err := st.Put(row[0], row[1], now); !errors.Is(err, ErrUnsealed) {
			t.Fatalf("stored an unsealed or swapped part: %v", err)
		}
	}
	id, _, err := st.Put(packet, preview, now)
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
	for _, name := range contentFiles {
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
	preview, packet, _, _ := loadVector(t)
	if _, _, err := st.Put(packet, []byte(`{}`), time.Now()); err == nil {
		t.Fatal("readable preview stored")
	}
	entries, err := os.ReadDir(st.dir)
	if err != nil || len(entries) != 0 {
		t.Fatal("failed upload left files")
	}
	id, _, err := st.Put(packet, preview, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	for _, rel := range []string{"", id, id + "/packet", id + "/" + previewFile, id + "/meta.json"} {
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

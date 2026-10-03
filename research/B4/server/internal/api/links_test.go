package api_test

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/url"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"spokenmargins.dev/bridge/internal/config"
	"spokenmargins.dev/bridge/internal/links"
)

type linksHarness struct {
	*harness
	store *links.Store
	dir   string
}

// newLinksHarness is the API harness with share links wired in and on.
func newLinksHarness(t *testing.T) *linksHarness {
	h := newHarness(t)
	dir := filepath.Join(t.TempDir(), "links")
	store, err := links.OpenStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	h.srv.LinkStore, h.srv.InstallURL = store, "https://spokenmargins.example/"
	if _, err := config.Set(h.configPath, config.ServiceLinks, true); err != nil {
		t.Fatal(err)
	}
	return &linksHarness{harness: h, store: store, dir: dir}
}

func linkPreview(edit func(map[string]any)) []byte {
	p := map[string]any{
		"schema": links.PreviewSchema,
		"source": map[string]any{"title": "The Long Walk", "show": "Field Notes", "url": "https://example.com/long-walk"},
		"margins": []map[string]any{
			{"text": "This is where it turns.", "before": "and then the river", "after": "rose over the bank"},
		},
	}
	if edit != nil {
		edit(p)
	}
	data, _ := json.Marshal(p)
	return data
}

func zipPacket(n int) []byte {
	b := bytes.Repeat([]byte{7}, n)
	copy(b, "PK\x03\x04")
	return b
}

// multipartBody builds the upload: preview first, then packet.
func multipartBody(preview, packet []byte) (*bytes.Buffer, string) {
	var b bytes.Buffer
	mw := multipart.NewWriter(&b)
	pw, _ := mw.CreateFormField("preview")
	pw.Write(preview)
	kw, _ := mw.CreateFormFile("packet", "shared.spokenmargins")
	kw.Write(packet)
	mw.Close()
	return &b, mw.FormDataContentType()
}

func (h *linksHarness) upload(t *testing.T, preview, packet []byte, forwardedFor string) (int, map[string]any) {
	t.Helper()
	body, ctype := multipartBody(preview, packet)
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+"/api/v1/links", body)
	req.Header.Set("Content-Type", ctype)
	if forwardedFor != "" {
		req.Header.Set("X-Forwarded-For", forwardedFor)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	decodeJSON(t, resp, &out)
	return resp.StatusCode, out
}

func (h *linksHarness) get(t *testing.T, path string) (*http.Response, []byte) {
	t.Helper()
	resp, err := http.Get(h.http.URL + path)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return resp, data
}

func TestLinkRoundTrip(t *testing.T) {
	h := newLinksHarness(t)
	packet := zipPacket(2 << 20)
	status, out := h.upload(t, linkPreview(nil), packet, "")
	if status != http.StatusCreated {
		t.Fatalf("upload: %d %v", status, out)
	}
	id, _ := out["id"].(string)
	if !links.ValidID(id) || out["path"] != "/l/"+id || out["expiresAt"] == "" {
		t.Fatalf("upload answer %v", out)
	}

	resp, page := h.get(t, "/l/"+id)
	if resp.StatusCode != 200 || !strings.HasPrefix(resp.Header.Get("Content-Type"), "text/html") {
		t.Fatalf("page: %d %s", resp.StatusCode, resp.Header.Get("Content-Type"))
	}
	if resp.Header.Get("Referrer-Policy") != "no-referrer" || resp.Header.Get("Content-Security-Policy") != links.PageCSP {
		t.Fatalf("page headers %v", resp.Header)
	}
	for _, want := range []string{"This is where it turns.", "and then the river", "Field Notes", `href="https://example.com/long-walk"`, "Report this link"} {
		if !strings.Contains(string(page), want) {
			t.Errorf("page missing %q", want)
		}
	}
	if strings.Contains(string(page), "<audio") {
		t.Error("page has an audio element")
	}

	resp, got := h.get(t, "/l/"+id+"/packet")
	if resp.StatusCode != 200 || sha256.Sum256(got) != sha256.Sum256(packet) {
		t.Fatalf("packet: %d, %d bytes, hash differs", resp.StatusCode, len(got))
	}
}

func TestLinkUploadRefusals(t *testing.T) {
	h := newLinksHarness(t)

	over := strings.Repeat("a", links.MaxExcerptChars+1)
	for side := range map[string]bool{"before": true, "after": true} {
		status, out := h.upload(t, linkPreview(func(p map[string]any) {
			p["margins"].([]map[string]any)[0][side] = over
		}), zipPacket(100), "")
		if status != 400 || out["error"] != "bad_preview" {
			t.Errorf("%s excerpt over 500: %d %v", side, status, out)
		}
	}
	if status, out := h.upload(t, linkPreview(nil), zipPacket(links.MaxPacketBytes+1), ""); status != 413 {
		t.Errorf("packet over 20 MB: %d %v", status, out)
	}
	if status, out := h.upload(t, linkPreview(nil), []byte("not a packet"), ""); status != 400 || out["error"] != "bad_packet" {
		t.Errorf("not a packet: %d %v", status, out)
	}
	// Packet before preview is refused before anything is written.
	var b bytes.Buffer
	mw := multipart.NewWriter(&b)
	kw, _ := mw.CreateFormFile("packet", "p")
	kw.Write(zipPacket(100))
	mw.Close()
	resp, err := http.Post(h.http.URL+"/api/v1/links", mw.FormDataContentType(), &b)
	if err != nil || resp.StatusCode != 400 {
		t.Errorf("packet first: %v %v", resp.Status, err)
	}
	resp, err = http.Post(h.http.URL+"/api/v1/links", "application/json", bytes.NewReader(linkPreview(nil)))
	if err != nil || resp.StatusCode != 400 {
		t.Errorf("not multipart: %v %v", resp.Status, err)
	}
	if entries, _ := filepath.Glob(filepath.Join(h.dir, "*")); len(entries) != 0 {
		t.Fatalf("refused uploads left files: %v", entries)
	}
}

func TestLinkUploadRateLimit(t *testing.T) {
	h := newLinksHarness(t)
	h.srv.TrustForwardedFor = true
	h.srv.LinkUploadsPerIPPerHour = 3
	for i := 0; i < 3; i++ {
		if status, out := h.upload(t, linkPreview(nil), zipPacket(100), "203.0.113.9"); status != 201 {
			t.Fatalf("upload %d: %d %v", i+1, status, out)
		}
	}
	if status, out := h.upload(t, linkPreview(nil), zipPacket(100), "203.0.113.9"); status != 429 {
		t.Fatalf("over the limit: %d %v", status, out)
	}
	// Another address still gets through: the counter is per address.
	if status, _ := h.upload(t, linkPreview(nil), zipPacket(100), "198.51.100.4"); status != 201 {
		t.Fatalf("other address: %d", status)
	}
	h.srv.Flush()
	if logs := h.reqLog.String() + h.abuseLog.String(); strings.Contains(logs, "203.0.113.9") {
		t.Fatalf("an address reached the logs:\n%s", logs)
	}
}

func TestLinksSwitchedOff(t *testing.T) {
	h := newLinksHarness(t)
	_, out := h.upload(t, linkPreview(nil), zipPacket(100), "")
	id := out["id"].(string)
	if _, err := config.Set(h.configPath, config.ServiceLinks, false); err != nil {
		t.Fatal(err)
	}
	if status, out := h.upload(t, linkPreview(nil), zipPacket(100), ""); status != 503 || out["error"] != "disabled" {
		t.Fatalf("upload with links off: %d %v", status, out)
	}
	for _, path := range []string{"/l/" + id, "/l/" + id + "/packet"} {
		if resp, _ := h.get(t, path); resp.StatusCode != 503 {
			t.Errorf("%s with links off: %d", path, resp.StatusCode)
		}
	}
	// Health and the other services don't depend on it.
	resp, body := h.get(t, "/api/v1/health")
	if resp.StatusCode != 200 || !strings.Contains(string(body), `"links":"off"`) {
		t.Fatalf("health: %d %s", resp.StatusCode, body)
	}
	if config.Default().Enabled(config.ServiceLinks) {
		t.Fatal("links must be off until the owner switches it on")
	}
}

func TestExpiredLinkAnswers410(t *testing.T) {
	h := newLinksHarness(t)
	_, out := h.upload(t, linkPreview(nil), zipPacket(100), "")
	id := out["id"].(string)
	h.srv.Now = func() time.Time { return time.Now().Add(links.Lifetime + time.Minute) }
	for _, path := range []string{"/l/" + id, "/l/" + id + "/packet"} {
		if resp, _ := h.get(t, path); resp.StatusCode != http.StatusGone {
			t.Errorf("%s after 30 days: %d", path, resp.StatusCode)
		}
	}
	if resp, _ := h.get(t, "/l/AAAAAAAAAAAAAAAAAAAAAA"); resp.StatusCode != 404 {
		t.Errorf("unknown id: %d", resp.StatusCode)
	}
}

func TestLinkReportAndLogsNeverNameTheID(t *testing.T) {
	h := newLinksHarness(t)
	_, out := h.upload(t, linkPreview(nil), zipPacket(100), "")
	id := out["id"].(string)
	h.get(t, "/l/"+id)
	h.get(t, "/l/"+id+"/packet")
	resp, err := http.PostForm(h.http.URL+"/l/"+id+"/report", url.Values{"reason": {"spam"}})
	if err != nil || resp.StatusCode != 200 {
		t.Fatalf("report: %v %v", resp.Status, err)
	}
	resp.Body.Close()
	// A made-up reason is recorded as "other", so the log only holds known words.
	resp, _ = http.PostForm(h.http.URL+"/l/"+id+"/report", url.Values{"reason": {"<b>free text</b>"}})
	resp.Body.Close()
	if err := h.srv.Flush(); err != nil {
		t.Fatal(err)
	}

	reqLog, abuse := h.reqLog.String(), h.abuseLog.String()
	if strings.Contains(reqLog, id) {
		t.Fatalf("request log names a link id:\n%s", reqLog)
	}
	for _, route := range []string{`"route":"/api/v1/links"`, `"route":"/l/*"`, `"route":"/l/*/packet"`, `"route":"/l/*/report"`} {
		if !strings.Contains(reqLog, route) {
			t.Errorf("request log missing %s:\n%s", route, reqLog)
		}
	}
	for _, want := range []string{fmt.Sprintf(`"link":%q`, id), `"reason":"report:spam"`, `"reason":"report:other"`} {
		if !strings.Contains(abuse, want) {
			t.Errorf("abuse log missing %s:\n%s", want, abuse)
		}
	}
	if strings.Contains(abuse, "free text") || strings.Contains(abuse, "127.0.0.1") {
		t.Fatalf("abuse log holds more than id and reason:\n%s", abuse)
	}

	// Reporting a link that doesn't exist records nothing.
	resp, _ = http.PostForm(h.http.URL+"/l/AAAAAAAAAAAAAAAAAAAAAA/report", url.Values{"reason": {"spam"}})
	if resp.StatusCode != 404 {
		t.Fatalf("report on unknown link: %d", resp.StatusCode)
	}
}

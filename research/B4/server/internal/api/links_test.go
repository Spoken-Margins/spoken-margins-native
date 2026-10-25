package api_test

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"spokenmargins.dev/bridge/internal/api"
	"spokenmargins.dev/bridge/internal/config"
	"spokenmargins.dev/bridge/internal/links"
	"spokenmargins.dev/bridge/internal/store"
)

// Drive the real handler in process; no listener or network is needed.
func linkServer(t *testing.T) (*api.Server, string) {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "public/api/v1/config.json")
	if err := config.Write(path, config.Default()); err != nil {
		t.Fatal(err)
	}
	st, err := store.Open(filepath.Join(dir, "state"))
	if err != nil {
		t.Fatal(err)
	}
	manifestPath := filepath.Join(dir, "public/bridge/v1/manifest.json")
	if err := os.MkdirAll(filepath.Dir(manifestPath), 0o755); err != nil {
		t.Fatal(err)
	}
	manifest, err := os.ReadFile("../../../contracts/fixtures/bridge-manifest.example.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(manifestPath, manifest, 0o644); err != nil {
		t.Fatal(err)
	}
	return &api.Server{Store: st, Config: &config.Reader{Path: path}, PublicDir: filepath.Join(dir, "public")}, path
}

func TestLinkServiceOffDoesNotBreakPublicDocuments(t *testing.T) {
	s, _ := linkServer(t)
	h := s.Handler()
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/api/v1/links", strings.NewReader("")))
	if w.Code != 503 {
		t.Fatalf("links off: HTTP %d, want 503", w.Code)
	}
	for _, path := range []string{"/api/v1/health", "/api/v1/config.json", "/bridge/v1/manifest.json"} {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest(http.MethodGet, path, nil))
		if w.Code != 200 {
			t.Errorf("%s: HTTP %d", path, w.Code)
		}
	}
}

const linkPreview = `{"source":{"title":"Source title","show":"Show name","url":"https://example.org/source"},"margins":[{"text":"Margin <b>text</b>","before":"before <script>","after":"after & text"}]}`

func enabledLinks(t *testing.T) (*api.Server, string) {
	t.Helper()
	s, path := linkServer(t)
	st, err := links.OpenStore(filepath.Join(filepath.Dir(s.PublicDir), "state", "links"))
	if err != nil {
		t.Fatal(err)
	}
	s.Links = st
	s.LinkInstallURL = "https://testflight.apple.com/join/fixture"
	if _, err := config.Set(path, config.ServiceLinks, true); err != nil {
		t.Fatal(err)
	}
	return s, path
}

func linkRequest(h http.Handler, method, path, contentType string, data []byte, addr string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, bytes.NewReader(data))
	r.RemoteAddr = addr + ":12345"
	if contentType != "" {
		r.Header.Set("Content-Type", contentType)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func multipartLink(t *testing.T, parts [][2][]byte) ([]byte, string) {
	t.Helper()
	var b bytes.Buffer
	mw := multipart.NewWriter(&b)
	for _, p := range parts {
		w, err := mw.CreateFormFile(string(p[0]), "upload")
		if err != nil {
			t.Fatal(err)
		}
		if _, err := w.Write(p[1]); err != nil {
			t.Fatal(err)
		}
	}
	if err := mw.Close(); err != nil {
		t.Fatal(err)
	}
	return b.Bytes(), mw.FormDataContentType()
}
func postLink(t *testing.T, h http.Handler, packet, preview []byte) *httptest.ResponseRecorder {
	data, ct := multipartLink(t, [][2][]byte{{[]byte("packet"), packet}, {[]byte("preview"), preview}})
	return linkRequest(h, "POST", "/api/v1/links", ct, data, "203.0.113.7")
}
func createdLink(t *testing.T, h http.Handler) string {
	t.Helper()
	w := postLink(t, h, []byte{'P', 'K', 0, 255, 42}, []byte(linkPreview))
	if w.Code != 201 {
		t.Fatalf("upload: %d %s", w.Code, w.Body)
	}
	var out struct {
		ID      string    `json:"id"`
		Expires time.Time `json:"expiresAt"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	b, err := hex.DecodeString(out.ID)
	if err != nil || len(b) < 16 || out.Expires.IsZero() {
		t.Fatalf("bad response %s", w.Body)
	}
	return out.ID
}

func TestLinkHTTPRoundTripReportsExpiryAndLogs(t *testing.T) {
	s, path := enabledLinks(t)
	now := time.Date(2026, 10, 7, 0, 0, 0, 0, time.UTC)
	s.Now = func() time.Time { return now }
	var reqLog, abuseLog bytes.Buffer
	s.RequestLog, s.AbuseLog = &reqLog, &abuseLog
	h := s.Handler()
	id := createdLink(t, h)
	w := linkRequest(h, "GET", "/l/"+id, "", nil, "203.0.113.7")
	if w.Code != 200 || !strings.Contains(w.Body.String(), "Margin &lt;b&gt;text&lt;/b&gt;") || !strings.Contains(w.Body.String(), "before &lt;script&gt;") {
		t.Fatalf("page: %d %s", w.Code, w.Body)
	}
	if w.Header().Get("Referrer-Policy") != "no-referrer" || w.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("page leaks referrer or can be cached past expiry")
	}
	w = linkRequest(h, "GET", "/l/"+id+"/packet", "", nil, "203.0.113.7")
	if w.Code != 200 || sha256.Sum256(w.Body.Bytes()) != sha256.Sum256([]byte{'P', 'K', 0, 255, 42}) {
		t.Fatal("HTTP packet hash round trip changed")
	}
	if w.Header().Get("Content-Type") != "application/octet-stream" {
		t.Fatal("packet can render as active content")
	}
	// Reports may write the id only to the abuse log, at the hourly flush.
	w = linkRequest(h, "POST", "/l/"+id+"/report", "application/x-www-form-urlencoded", []byte("reason=privacy"), "203.0.113.7")
	if w.Code != 200 {
		t.Fatalf("report: %d %s", w.Code, w.Body)
	}
	if reqLog.Len() != 0 || abuseLog.Len() != 0 {
		t.Fatal("per-request log write")
	}
	for _, suffix := range []string{"?query=SECRET", "/packet?token=SECRET", "/report/SECRET"} {
		linkRequest(h, "GET", "/l/"+id+suffix, "", nil, "203.0.113.7")
	}
	if err := s.Flush(); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(reqLog.String(), `"route":"/l/*"`) || !strings.Contains(reqLog.String(), `"route":"/api/v1/links"`) {
		t.Fatal("missing aggregate link routes")
	}
	for _, secret := range []string{id, "SECRET", "203.0.113.7", "Margin", "Source title"} {
		if strings.Contains(reqLog.String(), secret) {
			t.Fatalf("request log leaked %q: %s", secret, reqLog.String())
		}
	}
	if !strings.Contains(abuseLog.String(), `"id":"`+id+`"`) || !strings.Contains(abuseLog.String(), `"reason":"privacy"`) || strings.Contains(abuseLog.String(), "203.0.113.7") {
		t.Fatal("report log invalid")
	}
	now = now.Add(links.Lifetime)
	for _, suffix := range []string{"", "/packet"} {
		w = linkRequest(h, "GET", "/l/"+id+suffix, "", nil, "203.0.113.7")
		if w.Code != 410 {
			t.Fatalf("expired %s: %d", suffix, w.Code)
		}
	}
	if n, err := s.Links.Sweep(now); err != nil || n != 1 {
		t.Fatalf("sweep %d %v", n, err)
	}
	w = linkRequest(h, "GET", "/l/"+id, "", nil, "203.0.113.7")
	if w.Code != 410 {
		t.Fatal("swept id must still be 410")
	}
	if _, err := config.Set(path, config.ServiceLinks, false); err != nil {
		t.Fatal(err)
	}
	for _, suffix := range []string{"", "/packet"} {
		if w := linkRequest(h, "GET", "/l/"+id+suffix, "", nil, "203.0.113.7"); w.Code != 503 {
			t.Fatal("disabled fetch")
		}
	}
}

func TestLinkHTTPUploadValidation(t *testing.T) {
	for _, row := range []struct {
		name            string
		packet, preview []byte
		status          int
	}{
		{"packet over 20 MB", make([]byte, links.MaxPacketBytes+1), []byte(linkPreview), 413},
		{"packet exactly 20 MB", make([]byte, links.MaxPacketBytes), []byte(linkPreview), 201},
		{"empty packet", nil, []byte(linkPreview), 400},
		{"preview over 16 KB", []byte("packet"), bytes.Repeat([]byte(" "), links.MaxPreviewBytes+1), 413},
		{"before over 500", []byte("packet"), []byte(strings.Replace(linkPreview, "before <script>", strings.Repeat("x", 501), 1)), 400},
		{"after over 120", []byte("packet"), []byte(strings.Replace(linkPreview, "after & text", strings.Repeat("🎧", 121), 1)), 400},
		{"after exactly 120", []byte("packet"), []byte(strings.Replace(linkPreview, "after & text", strings.Repeat("🎧", 120), 1)), 201},
		{"invalid JSON", []byte("packet"), []byte(`{}`), 400},
		{"trailing JSON", []byte("packet"), []byte(linkPreview + ` null`), 400},
	} {
		t.Run(row.name, func(t *testing.T) {
			s, _ := enabledLinks(t)
			w := postLink(t, s.Handler(), row.packet, row.preview)
			if w.Code != row.status {
				t.Fatalf("HTTP %d %s, want %d", w.Code, w.Body, row.status)
			}
		})
	}
	s, _ := enabledLinks(t)
	h := s.Handler()
	for _, parts := range [][][2][]byte{
		{{[]byte("packet"), []byte("p")}},
		{{[]byte("preview"), []byte(linkPreview)}},
		{{[]byte("packet"), []byte("p")}, {[]byte("preview"), []byte(linkPreview)}, {[]byte("preview"), []byte(linkPreview)}},
		{{[]byte("unknown"), []byte("p")}, {[]byte("preview"), []byte(linkPreview)}},
	} {
		data, ct := multipartLink(t, parts)
		if w := linkRequest(h, "POST", "/api/v1/links", ct, data, "203.0.113.7"); w.Code != 400 {
			t.Fatalf("bad parts: %d", w.Code)
		}
	}
	// Preview-first uploads are also valid.
	data, ct := multipartLink(t, [][2][]byte{{[]byte("preview"), []byte(linkPreview)}, {[]byte("packet"), []byte("p")}})
	if w := linkRequest(h, "POST", "/api/v1/links", ct, data, "203.0.113.7"); w.Code != 201 {
		t.Fatalf("preview first: %d", w.Code)
	}
	if w := linkRequest(h, "POST", "/api/v1/links", "application/json", []byte(`{}`), "203.0.113.7"); w.Code != 400 {
		t.Fatal("bad content type")
	}
}

func TestLinkAddressLimitIsMemoryOnly(t *testing.T) {
	s, _ := enabledLinks(t)
	now := time.Now()
	s.Now = func() time.Time { return now }
	var reqLog, abuseLog bytes.Buffer
	s.RequestLog, s.AbuseLog = &reqLog, &abuseLog
	h := s.Handler()
	for i := 0; i < 30; i++ {
		if w := linkRequest(h, "POST", "/api/v1/links", "application/json", []byte(`{}`), "203.0.113.7"); w.Code != 400 {
			t.Fatalf("attempt %d: %d", i+1, w.Code)
		}
	}
	if w := linkRequest(h, "POST", "/api/v1/links", "application/json", []byte(`{}`), "203.0.113.7"); w.Code != 429 {
		t.Fatalf("attempt 31: %d", w.Code)
	}
	if w := linkRequest(h, "POST", "/api/v1/links", "application/json", []byte(`{}`), "198.51.100.2"); w.Code != 400 {
		t.Fatal("limits shared between addresses")
	}
	now = now.Add(time.Hour)
	createdLink(t, h)
	if err := s.Flush(); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(reqLog.String()+abuseLog.String(), "203.0.113.7") || strings.Contains(reqLog.String()+abuseLog.String(), "198.51.100.2") || abuseLog.Len() != 0 {
		t.Fatal("address persisted or rate limit logged an identity")
	}
	// Inspect the actual files, not just the log writers.
	filepath.WalkDir(filepath.Dir(s.PublicDir), func(path string, d os.DirEntry, err error) error {
		if err != nil {
			t.Fatal(err)
		}
		if !d.IsDir() {
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if bytes.Contains(data, []byte("203.0.113.7")) {
				t.Fatal("address on disk")
			}
		}
		return nil
	})
}

func TestLinkReportsRejectUnboundedReasons(t *testing.T) {
	s, _ := enabledLinks(t)
	var abuse bytes.Buffer
	s.AbuseLog = &abuse
	h := s.Handler()
	id := createdLink(t, h)
	for _, reason := range []string{"", "203.0.113.7", "<script>", strings.Repeat("x", 2000)} {
		w := linkRequest(h, "POST", "/l/"+id+"/report", "application/x-www-form-urlencoded", []byte("reason="+url.QueryEscape(reason)), "203.0.113.7")
		if w.Code != 400 {
			t.Fatalf("bad reason: %d", w.Code)
		}
	}
	if err := s.Flush(); err != nil {
		t.Fatal(err)
	}
	if abuse.Len() != 0 {
		t.Fatal("bad report logged")
	}
}

func TestLinkServiceMissingConfigurationFailsClosed(t *testing.T) {
	for _, missing := range []string{"store", "installURL"} {
		t.Run(missing, func(t *testing.T) {
			s, _ := enabledLinks(t)
			if missing == "store" {
				s.Links = nil
			} else {
				s.LinkInstallURL = ""
			}
			h := s.Handler()
			if w := postLink(t, h, []byte("packet"), []byte(linkPreview)); w.Code != 503 {
				t.Fatal("unconfigured service accepted upload")
			}
			for _, path := range []string{"/api/v1/health", "/api/v1/config.json", "/bridge/v1/manifest.json"} {
				if w := linkRequest(h, "GET", path, "", nil, "203.0.113.7"); w.Code != 200 {
					t.Fatalf("%s broken by unavailable links", path)
				}
			}
		})
	}
}

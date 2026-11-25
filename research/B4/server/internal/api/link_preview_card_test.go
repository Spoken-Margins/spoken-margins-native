package api_test

import (
	"bytes"
	"image/png"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"spokenmargins.dev/bridge/internal/config"
	"spokenmargins.dev/bridge/internal/links"
)

// A share link pasted into Messages, WhatsApp or mail gets a preview card (#5271). The link is sealed, so the card is
// one constant for every link: the tags below, written out here rather than read from links.PreviewTags.

var wantPreviewTags = map[string]string{
	"og:title":        "Margins from a friend",
	"og:description":  "Notes left at the moments they belong. Opens in your browser or in the Spoken Margins app.",
	"og:site_name":    "Spoken Margins",
	"og:type":         "website",
	"og:image":        "https://spokenmargins.com/l/card.png",
	"og:image:width":  "1200",
	"og:image:height": "630",
	"og:image:alt":    "Spoken Margins: a friend left you Margins.",
	"twitter:card":    "summary_large_image",
}

// The user agents preview fetchers send: Facebook's (which Messages and others reuse), WhatsApp's, X's, Slack's
// and Apple's link preview.
var previewFetchers = []string{
	"facebookexternalhit/1.1",
	"WhatsApp/2.23.20.0",
	"Twitterbot/1.0",
	"Slackbot-LinkExpanding 1.0",
	"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_11_1) AppleWebKit/601.2.4 (KHTML, like Gecko) Version/9.0.1 Safari/601.2.4 facebookexternalhit/1.1 Facebot Twitterbot/1.1",
}

var metaTag = regexp.MustCompile(`<meta (property|name)="([^"]+)" content="([^"]*)">`)

func botFetch(h http.Handler, path, userAgent string) *httptest.ResponseRecorder {
	r := httptest.NewRequest("GET", path, nil)
	r.RemoteAddr = "198.51.100.20:4321"
	r.Header.Set("User-Agent", userAgent)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

// previewTags reads the og: and twitter: tags a fetcher would, checking each uses the attribute fetchers read.
func previewTags(t *testing.T, body string) map[string]string {
	t.Helper()
	got := map[string]string{}
	for _, m := range metaTag.FindAllStringSubmatch(body, -1) {
		attr, key, value := m[1], m[2], m[3]
		switch {
		case strings.HasPrefix(key, "og:"):
			if attr != "property" {
				t.Errorf("%s uses %s=, want property=", key, attr)
			}
		case strings.HasPrefix(key, "twitter:"):
			if attr != "name" {
				t.Errorf("%s uses %s=, want name=", key, attr)
			}
		default:
			continue
		}
		if _, dup := got[key]; dup {
			t.Errorf("%s appears twice", key)
		}
		got[key] = value
	}
	return got
}

// tagBlock is the run of preview tags in a page, from the first og: tag to the end of twitter:card.
func tagBlock(t *testing.T, body string) string {
	t.Helper()
	start := strings.Index(body, `<meta property="og:`)
	endTag := `<meta name="twitter:card" content="summary_large_image">`
	end := strings.Index(body, endTag)
	if start < 0 || end < start {
		t.Fatalf("no preview tag block in: %s", body)
	}
	return body[start : end+len(endTag)]
}

func TestLinkPagePreviewTags(t *testing.T) {
	s, _ := enabledLinks(t)
	h := s.Handler()
	id := createdLink(t, h)
	for _, agent := range previewFetchers {
		w := botFetch(h, "/l/"+id, agent)
		if w.Code != 200 {
			t.Fatalf("%s: HTTP %d", agent, w.Code)
		}
		got := previewTags(t, w.Body.String())
		for key, want := range wantPreviewTags {
			if got[key] != want {
				t.Errorf("%s: %s = %q, want %q", agent, key, got[key], want)
			}
		}
		if len(got) != len(wantPreviewTags) {
			t.Errorf("%s: %d preview tags, want %d: %v", agent, len(got), len(wantPreviewTags), got)
		}
		if _, ok := got["og:url"]; ok {
			t.Errorf("%s: og:url would differ by link", agent)
		}
		if strings.Contains(tagBlock(t, w.Body.String()), id) {
			t.Errorf("%s: the tag block names the link", agent)
		}
	}
}

// Nothing in the tags differs by link: two live links, an unknown one, an expired one, a taken-down one and the
// service switched off all carry the same block. Only the status code still differs, as it did before.
func TestPreviewTagsSameForEveryLink(t *testing.T) {
	s, path := enabledLinks(t)
	now := time.Date(2026, 11, 24, 0, 0, 0, 0, time.UTC)
	s.Now = func() time.Time { return now }
	h := s.Handler()
	live1, live2 := createdLink(t, h), createdLink(t, h)
	removed := createdLink(t, h)
	if w := linkRequest(h, "POST", "/l/"+removed+"/report", "application/x-www-form-urlencoded", []byte("category=copyright"), "203.0.113.7"); w.Code != 200 {
		t.Fatalf("report: %d %s", w.Code, w.Body)
	}
	agent := previewFetchers[0]
	blocks := map[string]string{}
	fetch := func(name, id string, status int) {
		w := botFetch(h, "/l/"+id, agent)
		if w.Code != status {
			t.Errorf("%s: HTTP %d, want %d", name, w.Code, status)
		}
		blocks[name] = tagBlock(t, w.Body.String())
	}
	fetch("live 1", live1, 200)
	fetch("live 2", live2, 200)
	fetch("unknown", strings.Repeat("0", 32), 404)
	fetch("taken down", removed, 410)
	expiring := live1
	now = now.Add(links.Lifetime)
	fetch("expired", expiring, 410)
	if _, err := config.Set(path, config.ServiceLinks, false); err != nil {
		t.Fatal(err)
	}
	fetch("links off", live2, 503)
	want := blocks["live 1"]
	if got := previewTags(t, want); got["og:title"] != wantPreviewTags["og:title"] {
		t.Fatalf("live page has no card: %v", got)
	}
	for name, block := range blocks {
		if block != want {
			t.Errorf("%s: tag block differs:\n%s\nwant:\n%s", name, block, want)
		}
	}
}

// A preview fetch is not the friend opening the link: it neither uses the link up nor extends it. Some fetchers
// request every address on a page, so the two data routes are fetched too.
func TestPreviewFetchChangesNothing(t *testing.T) {
	s, _ := enabledLinks(t)
	h := s.Handler()
	id := createdLink(t, h)
	meta := filepath.Join(filepath.Dir(s.PublicDir), "state", "links", id, "meta.json")
	before, err := os.ReadFile(meta)
	if err != nil {
		t.Fatal(err)
	}
	beforeInfo, err := os.Stat(meta)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 10; i++ {
		for _, p := range []string{"/l/" + id, "/l/" + id + "/preview", "/l/" + id + "/packet", "/l/card.png"} {
			if w := botFetch(h, p, previewFetchers[i%len(previewFetchers)]); w.Code != 200 {
				t.Fatalf("%s: HTTP %d", p, w.Code)
			}
		}
	}
	after, err := os.ReadFile(meta)
	if err != nil {
		t.Fatal(err)
	}
	afterInfo, err := os.Stat(meta)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before, after) {
		t.Errorf("meta.json changed:\nbefore %s\nafter  %s", before, after)
	}
	if !beforeInfo.ModTime().Equal(afterInfo.ModTime()) {
		t.Errorf("meta.json modified time changed: %v -> %v", beforeInfo.ModTime(), afterInfo.ModTime())
	}
}

// The card's picture: a 1200 x 630 PNG under WhatsApp's 300 KB ceiling, cacheable, served while links are off too.
func TestLinkCardImage(t *testing.T) {
	s, path := enabledLinks(t)
	h := s.Handler()
	check := func(name string) {
		w := botFetch(h, "/l/card.png", "WhatsApp/2.23.20.0")
		if w.Code != 200 {
			t.Fatalf("%s: HTTP %d %s", name, w.Code, w.Body)
		}
		for header, want := range map[string]string{
			"Content-Type":           "image/png",
			"Cache-Control":          "public, max-age=86400",
			"X-Content-Type-Options": "nosniff",
			"X-Robots-Tag":           "noindex",
		} {
			if got := w.Header().Get(header); got != want {
				t.Errorf("%s: %s = %q, want %q", name, header, got, want)
			}
		}
		if got := w.Header().Get("Access-Control-Allow-Origin"); got != "" {
			t.Errorf("%s: CORS header %q on the card", name, got)
		}
		if n := w.Body.Len(); n > 300*1024 {
			t.Errorf("%s: card is %d bytes, over 300 KB", name, n)
		}
		img, err := png.Decode(bytes.NewReader(w.Body.Bytes()))
		if err != nil {
			t.Fatalf("%s: not a PNG: %v", name, err)
		}
		if b := img.Bounds(); b.Dx() != 1200 || b.Dy() != 630 {
			t.Errorf("%s: card is %dx%d, want 1200x630", name, b.Dx(), b.Dy())
		}
	}
	check("links on")
	if _, err := config.Set(path, config.ServiceLinks, false); err != nil {
		t.Fatal(err)
	}
	check("links off")
}

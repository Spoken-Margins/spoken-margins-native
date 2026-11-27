package api_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"spokenmargins.dev/bridge/internal/api"
	"spokenmargins.dev/bridge/internal/config"
	"spokenmargins.dev/bridge/internal/links"
)

// Opened marks (#5275): a friend's client posts the link's opened-token on Play; the sender's app asks with
// the same token. The vector is the one the phone and the browser make from the link's key and id.
var openedToken, otherOpenedToken = func() (string, string) {
	data, err := os.ReadFile("../../../contracts/fixtures/share-link-opened-token.json")
	if err != nil {
		panic(err)
	}
	var v struct{ TokenHex, OtherTokenHex string }
	if err := json.Unmarshal(data, &v); err != nil {
		panic(err)
	}
	return v.TokenHex, v.OtherTokenHex
}()

func postOpened(h http.Handler, id, body, addr string) *httptest.ResponseRecorder {
	return linkRequest(h, "POST", "/l/"+id+"/opened", "text/plain;charset=UTF-8", []byte(body), addr)
}

func getOpened(t *testing.T, h http.Handler, id, token string) (int, bool) {
	t.Helper()
	r := httptest.NewRequest("GET", "/l/"+id+"/opened", nil)
	r.RemoteAddr = "198.51.100.4:12345"
	if token != "" {
		r.Header.Set(api.LinkOpenedTokenHeader, token)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 200 {
		return w.Code, false
	}
	if w.Header().Get("Cache-Control") != "no-store" || w.Header().Get("Access-Control-Allow-Origin") != "" {
		t.Fatalf("GET opened headers %v", w.Header())
	}
	var out struct {
		Opened *bool `json:"opened"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil || out.Opened == nil {
		t.Fatalf("GET opened body %s", w.Body)
	}
	return w.Code, *out.Opened
}

func linkMetaPath(s *api.Server, id string) string {
	return filepath.Join(filepath.Dir(s.PublicDir), "state", "links", id, "meta.json")
}

func TestOpenedStoresOnlyTheMark(t *testing.T) {
	s, _ := enabledLinks(t)
	made := time.Date(2026, 11, 24, 9, 0, 0, 0, time.UTC)
	now := made
	s.Now = func() time.Time { return now }
	h := s.Handler()
	id := createdLink(t, h)
	now = made.Add(3*24*time.Hour + 5*time.Hour + 17*time.Minute)
	if w := postOpened(h, id, openedToken, "203.0.113.9"); w.Code != 204 || w.Body.Len() != 0 {
		t.Fatalf("POST opened: %d %s", w.Code, w.Body)
	}
	data, err := os.ReadFile(linkMetaPath(s, id))
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		t.Fatal(err)
	}
	keys := []string{}
	for k := range fields {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	if strings.Join(keys, ",") != "expiresAt,openedMarks" {
		t.Fatalf("meta.json holds %v, want only expiresAt and openedMarks", keys)
	}
	for _, leak := range []string{openedToken, "203.0.113.9", "2026-11-27", "T14:17"} {
		if bytes.Contains(data, []byte(leak)) {
			t.Fatalf("meta.json holds %q: %s", leak, data)
		}
	}
	info, err := os.Stat(linkMetaPath(s, id))
	if err != nil {
		t.Fatal(err)
	}
	if !info.ModTime().Equal(made) {
		t.Fatalf("meta.json modified %v, want the creation time %v", info.ModTime().UTC(), made)
	}
	// Nothing else under the server's state took the open: no file holds the token or the address.
	filepath.WalkDir(filepath.Dir(s.PublicDir), func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		data, _ := os.ReadFile(path)
		if bytes.Contains(data, []byte(openedToken)) || bytes.Contains(data, []byte("203.0.113.9")) {
			t.Fatalf("%s holds the token or the friend's address", path)
		}
		return nil
	})
	if code, opened := getOpened(t, h, id, openedToken); code != 200 || !opened {
		t.Fatalf("GET opened: %d %v", code, opened)
	}
}

func TestOpenedNeedsTheToken(t *testing.T) {
	s, _ := enabledLinks(t)
	h := s.Handler()
	id := createdLink(t, h)
	// A post with someone else's token doesn't make the real one read opened.
	postOpened(h, id, otherOpenedToken, "203.0.113.9")
	if _, opened := getOpened(t, h, id, openedToken); opened {
		t.Fatal("another token's post reads as opened")
	}
	postOpened(h, id, openedToken, "203.0.113.9")
	if _, opened := getOpened(t, h, id, openedToken); !opened {
		t.Fatal("the real post does not read as opened")
	}
	if code, _ := getOpened(t, h, id, ""); code != 400 {
		t.Fatalf("GET without a token: %d, want 400", code)
	}
	for _, bad := range []string{"", "opened", strings.ToUpper(openedToken), openedToken + "\n", openedToken + openedToken, strings.Repeat("a", 4096)} {
		if w := postOpened(h, id, bad, "203.0.113.9"); w.Code != 400 {
			t.Errorf("POST %.20q: %d, want 400", bad, w.Code)
		}
	}
	if w := postOpened(h, "not-a-link", openedToken, "203.0.113.9"); w.Code != 400 {
		t.Errorf("POST to a malformed id: %d, want 400", w.Code)
	}
}

// Every well-formed post gets the same empty 204, so the answer says nothing about the link.
func TestOpenedSameAnswerEveryId(t *testing.T) {
	s, _ := enabledLinks(t)
	now := time.Date(2026, 11, 24, 0, 0, 0, 0, time.UTC)
	s.Now = func() time.Time { return now }
	h := s.Handler()
	live, expired, disabled, down := createdLink(t, h), "", createdLink(t, h), createdLink(t, h)
	now = now.Add(-links.Lifetime)
	expired = createdLink(t, h)
	now = now.Add(links.Lifetime)
	if err := s.Links.Disable(disabled, now); err != nil {
		t.Fatal(err)
	}
	if err := s.Links.Takedown(down); err != nil {
		t.Fatal(err)
	}
	for name, id := range map[string]string{"live": live, "unknown": "0123456789abcdef0123456789abcdef", "expired": expired, "disabled": disabled, "taken down": down} {
		w := postOpened(h, id, openedToken, "203.0.113.9")
		if w.Code != 204 || w.Body.Len() != 0 {
			t.Errorf("%s: %d %q", name, w.Code, w.Body)
		}
		if _, opened := getOpened(t, h, id, openedToken); opened != (name == "live") {
			t.Errorf("%s reads opened=%v", name, opened)
		}
	}
}

func TestOpenedAfterDisableAndTakedown(t *testing.T) {
	s, _ := enabledLinks(t)
	h := s.Handler()
	disabled, down := createdLink(t, h), createdLink(t, h)
	for _, id := range []string{disabled, down} {
		postOpened(h, id, openedToken, "203.0.113.9")
		if _, opened := getOpened(t, h, id, openedToken); !opened {
			t.Fatal("not opened before the takedown")
		}
	}
	if err := s.Links.Disable(disabled, s.Now()); err != nil {
		t.Fatal(err)
	}
	if err := s.Links.Takedown(down); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{disabled, down} {
		if _, opened := getOpened(t, h, id, openedToken); opened {
			t.Fatalf("%s still reads opened", id)
		}
		if data, _ := os.ReadFile(linkMetaPath(s, id)); bytes.Contains(data, []byte("openedMarks")) {
			t.Fatalf("%s kept its mark: %s", id, data)
		}
	}
}

func TestOpenedDoesNotExtendLink(t *testing.T) {
	s, _ := enabledLinks(t)
	now := time.Date(2026, 11, 24, 0, 0, 0, 0, time.UTC)
	s.Now = func() time.Time { return now }
	h := s.Handler()
	id := createdLink(t, h)
	now = now.Add(links.Lifetime - time.Minute)
	postOpened(h, id, openedToken, "203.0.113.9")
	now = now.Add(time.Minute)
	if w := linkRequest(h, "GET", "/l/"+id+"/packet", "", nil, "203.0.113.9"); w.Code != 410 {
		t.Fatalf("packet at 30 days after an open: %d, want 410", w.Code)
	}
}

// Its own window: 30 posts an hour per client network, and a friend's report allowance is untouched.
func TestOpenedRateLimited(t *testing.T) {
	s, _ := enabledLinks(t)
	h := s.Handler()
	id, reported := createdLink(t, h), createdLink(t, h)
	for i := 0; i < 30; i++ {
		if w := postOpened(h, id, openedToken, "203.0.113.9"); w.Code != 204 {
			t.Fatalf("post %d: %d", i+1, w.Code)
		}
	}
	if w := postOpened(h, id, openedToken, "203.0.113.9"); w.Code != 429 {
		t.Fatalf("31st post: %d, want 429", w.Code)
	}
	if w := postOpened(h, id, openedToken, "198.51.100.200"); w.Code != 204 {
		t.Fatalf("another network: %d", w.Code)
	}
	w := linkRequest(h, "POST", "/l/"+reported+"/report", "application/x-www-form-urlencoded", []byte("category=copyright"), "203.0.113.9")
	if w.Code != 200 {
		t.Fatalf("a report after 30 opened posts: %d %s", w.Code, w.Body)
	}
}

// A messenger building a preview card, a link scanner or the page loading fetches only by GET and never
// holds the key, so none of it can open a link (#5271, #5275).
func TestPreviewFetchIsNotAnOpen(t *testing.T) {
	s, _ := enabledLinks(t)
	h := s.Handler()
	id := createdLink(t, h)
	for _, agent := range []string{"facebookexternalhit/1.1", "WhatsApp/2.23.20.0", "Twitterbot/1.0", "Slackbot-LinkExpanding 1.0", "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X)"} {
		for _, suffix := range []string{"", "/preview", "/packet", "/opened"} {
			r := httptest.NewRequest("GET", "/l/"+id+suffix, nil)
			r.RemoteAddr = "203.0.113.9:443"
			r.Header.Set("User-Agent", agent)
			h.ServeHTTP(httptest.NewRecorder(), r)
		}
	}
	if _, opened := getOpened(t, h, id, openedToken); opened {
		t.Fatal("fetching the page, preview or packet opened the link")
	}
	if data, _ := os.ReadFile(linkMetaPath(s, id)); bytes.Contains(data, []byte("openedMarks")) {
		t.Fatalf("a fetch left a mark: %s", data)
	}
}

// The request log names only /l/*, never the id or the token, and logs nothing per request.
func TestOpenedNotLogged(t *testing.T) {
	s, _ := enabledLinks(t)
	var reqLog, abuseLog bytes.Buffer
	s.RequestLog, s.AbuseLog = &reqLog, &abuseLog
	h := s.Handler()
	id := createdLink(t, h)
	reqLog.Reset()
	postOpened(h, id, openedToken, "203.0.113.9")
	getOpened(t, h, id, openedToken)
	if reqLog.Len() != 0 || abuseLog.Len() != 0 {
		t.Fatal("per-request log write")
	}
	if err := s.Flush(); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(reqLog.String(), `"route":"/l/*"`) {
		t.Fatalf("missing the aggregate route: %s", reqLog.String())
	}
	for _, secret := range []string{id, openedToken, "opened", "203.0.113.9"} {
		if strings.Contains(reqLog.String()+abuseLog.String(), secret) {
			t.Fatalf("a log holds %q: %s %s", secret, reqLog.String(), abuseLog.String())
		}
	}
}

// The last shipped app and the current share page get the same bytes as before an open, and one new header.
func TestLastShippedClientUnaffected(t *testing.T) {
	s, _ := enabledLinks(t)
	h := s.Handler()
	id := createdLink(t, h)
	before := linkRequest(h, "GET", "/l/"+id+"/packet", "", nil, "203.0.113.9")
	postOpened(h, id, openedToken, "203.0.113.9")
	w := linkRequest(h, "GET", "/l/"+id+"/packet", "", nil, "203.0.113.9")
	if w.Code != 200 || !bytes.Equal(w.Body.Bytes(), linkPacket) {
		t.Fatalf("packet after an open: %d, bytes changed", w.Code)
	}
	if w.Header().Get(api.LinkOpenedHeader) != "1" {
		t.Fatalf("packet lacks %s", api.LinkOpenedHeader)
	}
	for k := range w.Header() {
		if _, ok := before.Header()[k]; !ok {
			t.Fatalf("packet gained header %s after an open", k)
		}
	}
	if w := linkRequest(h, "GET", "/l/"+id+"/preview", "", nil, "203.0.113.9"); w.Code != 200 || !bytes.Equal(w.Body.Bytes(), linkPreview) {
		t.Fatalf("preview after an open: %d", w.Code)
	}
	var page bytes.Buffer
	if err := links.Render(&page, id, s.LinkInstallURL, s.LinkWebURL); err != nil {
		t.Fatal(err)
	}
	if w := linkRequest(h, "GET", "/l/"+id, "", nil, "203.0.113.9"); w.Code != 200 || !bytes.Equal(w.Body.Bytes(), page.Bytes()) {
		t.Fatalf("page after an open: %d", w.Code)
	}
	// The packet's headers are the pre-#5275 set plus the one new header, so an old client sees nothing else.
	want := map[string]bool{}
	for _, k := range []string{"Cache-Control", "Referrer-Policy", "X-Content-Type-Options", "X-Robots-Tag", "Content-Security-Policy",
		api.LinkExpiresHeader, "Content-Type", "Content-Disposition", "Accept-Ranges", "Content-Length", api.LinkOpenedHeader} {
		want[http.CanonicalHeaderKey(k)] = true
	}
	for k := range w.Header() {
		if !want[http.CanonicalHeaderKey(k)] && !want[k] {
			t.Errorf("packet answers an unexpected header %s", k)
		}
	}
}

func TestOpenedRoutesFollowTheLinksSwitch(t *testing.T) {
	s, path := enabledLinks(t)
	h := s.Handler()
	id := createdLink(t, h)
	if _, err := config.Set(path, config.ServiceLinks, false); err != nil {
		t.Fatal(err)
	}
	if w := postOpened(h, id, openedToken, "203.0.113.9"); w.Code != 503 {
		t.Fatalf("POST with links off: %d", w.Code)
	}
	if code, _ := getOpened(t, h, id, openedToken); code != 503 {
		t.Fatalf("GET with links off: %d", code)
	}
}

// The web app reads the new header across origins; the share page's own fetch needs nothing.
func TestOpenedHeaderExposedToTheWebApp(t *testing.T) {
	s, _ := enabledLinks(t)
	s.LinkOrigins = []string{"https://app.example"}
	h := s.Handler()
	id := createdLink(t, h)
	r := httptest.NewRequest("GET", "/l/"+id+"/packet", nil)
	r.Header.Set("Origin", "https://app.example")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if got := w.Header().Get("Access-Control-Expose-Headers"); !strings.Contains(got, api.LinkOpenedHeader) || !strings.Contains(got, api.LinkExpiresHeader) {
		t.Fatalf("exposed headers %q", got)
	}
}

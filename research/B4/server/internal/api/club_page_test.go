package api_test

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"spokenmargins.dev/bridge/internal/config"
	"spokenmargins.dev/bridge/internal/links"
)

// The page a club invite opens in a browser (#1799, docs/design/club-mailbox.md section 10, slice 4). The server
// never looks the club up and cannot see the key, so the page is the same for every id of the right shape.

const (
	pageUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1"
	androidAgent  = "Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 Chrome/130.0 Mobile Safari/537.36"
)

func (c *clubHarness) page(path, userAgent string) (int, string, string) {
	c.t.Helper()
	r := httptest.NewRequest("GET", path, nil)
	r.RemoteAddr = clubAddr + ":4321"
	r.Header.Set("User-Agent", userAgent)
	w := httptest.NewRecorder()
	c.h.ServeHTTP(w, r)
	return w.Code, w.Header().Get("Content-Type"), w.Body.String()
}

func TestClubPageIsTheSameForAClubAnEndedClubAndAnIdNobodyMade(t *testing.T) {
	c := newClubHarness(t)
	c.srv.LinkInstallURL = "https://testflight.apple.com/join/fixture"
	live, ended, never := deriveClub(t, secretK(1)), deriveClub(t, secretK(2)), deriveClub(t, secretK(3))
	for _, k := range []clubKeys{live, ended} {
		if got := c.create(k, sealedPart(links.PartClubHeader, 200, "header"), clubAddr); got.code != 201 {
			t.Fatalf("create: %d %s", got.code, got.body)
		}
	}
	if err := c.srv.Clubs.Takedown(ended.id, c.clock.Now()); err != nil {
		t.Fatal(err)
	}

	// The page bytes differ only by the id the address carries.
	bodies := map[string]string{}
	for name, k := range map[string]clubKeys{"live": live, "ended": ended, "never made": never} {
		code, contentType, body := c.page("/c/"+k.id, pageUserAgent)
		if code != 200 {
			t.Errorf("%s: HTTP %d", name, code)
		}
		if !strings.HasPrefix(contentType, "text/html") {
			t.Errorf("%s: Content-Type %q", name, contentType)
		}
		bodies[name] = strings.ReplaceAll(body, k.id, "ID")
	}
	if bodies["live"] != bodies["ended"] || bodies["live"] != bodies["never made"] {
		t.Errorf("the pages differ:\nlive: %s\nended: %s\nnever made: %s", bodies["live"], bodies["ended"], bodies["never made"])
	}
	for _, want := range []string{
		`<h1>You're invited to a club</h1>`, `src="/c/club-page.mjs"`, `id="open"`, `Open in Spoken Margins`,
		`href="https://testflight.apple.com/join/fixture"`, `href="/privacy/"`,
	} {
		if !strings.Contains(bodies["live"], want) {
			t.Errorf("the page lacks %q: %s", want, bodies["live"])
		}
	}
	// The button is hidden until the script has a key to hand over, and carries none of its own.
	if !strings.Contains(bodies["live"], `href="spokenmargins://club" hidden`) {
		t.Errorf("the open button is not hidden or names more than the scheme: %s", bodies["live"])
	}
}

func TestClubPageHoldsNeitherAKeyNorAProofNorAnyAnswerAboutTheClub(t *testing.T) {
	c := newClubHarness(t)
	k := deriveClub(t, secretK(4))
	if got := c.create(k, sealedPart(links.PartClubHeader, 200, "header"), clubAddr); got.code != 201 {
		t.Fatalf("create: %d", got.code)
	}
	_, _, body := c.page("/c/"+k.id, pageUserAgent)
	for what, secret := range map[string]string{"read proof": k.read, "post proof": k.post, "read hash": k.readHash, "post hash": k.postHash} {
		if strings.Contains(body, secret) {
			t.Errorf("the page holds the %s", what)
		}
	}
	// A query or a fragment-looking tail changes nothing: the server reads neither.
	_, _, withQuery := c.page("/c/"+k.id+"?key=abc", pageUserAgent)
	if withQuery != body {
		t.Errorf("a query changed the page")
	}
	if strings.Contains(body, "abc") {
		t.Errorf("the page echoed the query")
	}
}

func TestClubPageWritesNothingAndLogsOnlyTheRouteName(t *testing.T) {
	c := newClubHarness(t)
	k := deriveClub(t, secretK(5))
	c.create(k, sealedPart(links.PartClubHeader, 200, "header"), clubAddr)
	before := folderSnapshot(t, c.stateDir)
	for i := 0; i < 3; i++ {
		c.page("/c/"+k.id, pageUserAgent)
	}
	c.page("/c/club-page.mjs", pageUserAgent)
	c.page("/c/"+strings.ToUpper(k.id), pageUserAgent)
	if after := folderSnapshot(t, c.stateDir); after != before {
		t.Errorf("a page request changed the state folder:\nbefore: %s\nafter: %s", before, after)
	}
	if err := c.srv.Flush(); err != nil {
		t.Fatal(err)
	}
	for name, log := range map[string]string{"request log": c.reqLog.String(), "abuse log": c.abuseLog.String()} {
		if strings.Contains(log, k.id) || strings.Contains(log, strings.ToUpper(k.id)) {
			t.Errorf("the %s names the club: %s", name, log)
		}
	}
	if !strings.Contains(c.reqLog.String(), `"route":"/c/*"`) {
		t.Errorf("the page requests are not logged as /c/*: %s", c.reqLog.String())
	}
}

// folderSnapshot is every path under dir with its modification time and the hash of its content.
func folderSnapshot(t *testing.T, dir string) string {
	t.Helper()
	var b strings.Builder
	filepath.WalkDir(dir, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		info, _ := d.Info()
		rel, _ := filepath.Rel(dir, p)
		sum := ""
		if !d.IsDir() {
			data, _ := os.ReadFile(p)
			sum = fmt.Sprintf("%x", sha256.Sum256(data))
		}
		b.WriteString(rel + "|" + info.ModTime().UTC().String() + "|" + sum + "\n")
		return nil
	})
	return b.String()
}

func TestClubPageWordsAnAddressThatCannotBeAClub(t *testing.T) {
	c := newClubHarness(t)
	valid := deriveClub(t, secretK(6)).id
	var first string
	for name, id := range map[string]string{
		"too short":  valid[:31],
		"too long":   valid + "0",
		"upper case": strings.ToUpper(valid),
		"not hex":    valid[:31] + "g",
		"encoded":    valid[:29] + "%2fab",
		"space":      valid[:31] + "%20",
	} {
		code, contentType, body := c.page("/c/"+id, pageUserAgent)
		if code != 404 || !strings.HasPrefix(contentType, "text/html") {
			t.Errorf("%s: HTTP %d %s", name, code, contentType)
		}
		for _, raw := range []string{`{"error"`, "not_found", `"error":`} {
			if strings.Contains(body, raw) {
				t.Errorf("%s: the page shows %q", name, raw)
			}
		}
		if !strings.Contains(body, "<h1>This invite isn&#39;t available</h1>") || !strings.Contains(body, "Copy the whole link") {
			t.Errorf("%s: no plain words: %s", name, body)
		}
		if first == "" {
			first = body
		} else if body != first {
			t.Errorf("%s: the page differs from another malformed address's", name)
		}
	}
}

func TestClubPageSwitchOffAnswersAPageAndTheScriptStops(t *testing.T) {
	c := newClubHarness(t)
	k := deriveClub(t, secretK(7))
	if _, err := config.Set(c.configPath, config.ServiceClubs, false); err != nil {
		t.Fatal(err)
	}
	code, contentType, body := c.page("/c/"+k.id, pageUserAgent)
	if code != 503 || !strings.HasPrefix(contentType, "text/html") || !strings.Contains(body, "<h1>Clubs are paused</h1>") {
		t.Errorf("page off: HTTP %d %s %s", code, contentType, body)
	}
	if strings.Contains(body, k.id) {
		t.Errorf("the paused page names the club")
	}
	if got := c.do("GET", "/c/club-page.mjs", nil, "", clubAddr); got.code != 503 {
		t.Errorf("script off: HTTP %d", got.code)
	}
	// The malformed-address page and the paused page are one decision for every id: the switch wins.
	if code, _, _ := c.page("/c/not-an-id", pageUserAgent); code != 503 {
		t.Errorf("a malformed address with the switch off: HTTP %d, want 503", code)
	}
}

func TestClubPageOffersTheInstallLinkOnlyToABrowserThatCanUseIt(t *testing.T) {
	c := newClubHarness(t)
	k := deriveClub(t, secretK(8))
	c.srv.LinkInstallURL = "https://testflight.apple.com/join/fixture"
	_, _, iphone := c.page("/c/"+k.id, pageUserAgent)
	_, _, android := c.page("/c/"+k.id, androidAgent)
	if !strings.Contains(iphone, "Get Spoken Margins") || strings.Contains(android, "Get Spoken Margins") || strings.Contains(android, "testflight") {
		t.Errorf("install link: iPhone %v, Android %v", strings.Contains(iphone, "Get Spoken Margins"), strings.Contains(android, "Get Spoken Margins"))
	}
	// No valid install link configured: the page still works, without that sentence.
	c.srv.LinkInstallURL = ""
	code, _, none := c.page("/c/"+k.id, pageUserAgent)
	if code != 200 || strings.Contains(none, "Get Spoken Margins") || !strings.Contains(none, "Open in Spoken Margins") {
		t.Errorf("no install link: HTTP %d: %s", code, none)
	}
	c.srv.LinkInstallURL = "https://evil.example/join/x"
	_, _, bad := c.page("/c/"+k.id, pageUserAgent)
	if strings.Contains(bad, "evil.example") {
		t.Errorf("an install link that is not a real listing reached the page")
	}
}

func TestClubPageKeepsTheSecurityHeadersAndFetchesNothing(t *testing.T) {
	c := newClubHarness(t)
	k := deriveClub(t, secretK(9))
	for _, path := range []string{"/c/" + k.id, "/c/club-page.mjs", "/c/nonsense"} {
		got := c.do("GET", path, nil, "", clubAddr)
		for header, want := range map[string]string{
			"Cache-Control": "no-store", "Referrer-Policy": "no-referrer", "X-Robots-Tag": "noindex, nofollow", "X-Content-Type-Options": "nosniff",
		} {
			if have := got.hdr.Get(header); have != want {
				t.Errorf("%s: %s = %q, want %q", path, header, have, want)
			}
		}
		csp := got.hdr.Get("Content-Security-Policy")
		for _, want := range []string{"default-src 'none'", "script-src 'self'", "frame-ancestors 'none'", "form-action 'none'"} {
			if !strings.Contains(csp, want) {
				t.Errorf("%s: CSP %q lacks %q", path, csp, want)
			}
		}
		// Nothing lets the page connect anywhere, and nothing but its own module may run.
		if strings.Contains(csp, "connect-src") || strings.Contains(csp, "unsafe-eval") || strings.Contains(csp, "script-src 'unsafe") {
			t.Errorf("%s: CSP %q is wider than it needs", path, csp)
		}
	}
}

func TestClubScriptIsServedAndMakesNoRequest(t *testing.T) {
	c := newClubHarness(t)
	got := c.do("GET", "/c/club-page.mjs", nil, "", clubAddr)
	if got.code != 200 || !strings.HasPrefix(got.hdr.Get("Content-Type"), "text/javascript") {
		t.Fatalf("script: HTTP %d %s", got.code, got.hdr.Get("Content-Type"))
	}
	onDisk, err := os.ReadFile("../clubs/club-page.mjs")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got.body, onDisk) {
		t.Errorf("the served script is not the file")
	}
	// The page opens nothing but an address in the app: no network call of any kind may appear in it.
	for _, banned := range []string{"fetch(", "XMLHttpRequest", "sendBeacon", "WebSocket", "EventSource", "import(", "localStorage", "sessionStorage", "document.cookie", "location.replace", "location.assign", "location.href ="} {
		if bytes.Contains(got.body, []byte(banned)) {
			t.Errorf("the script uses %s", banned)
		}
	}
	// No other file is reachable under the script's name.
	for _, path := range []string{"/c/other.mjs", "/c/club-page.mjs/x", "/c/CLUB-PAGE.MJS"} {
		if got := c.do("GET", path, nil, "", clubAddr); got.code == 200 {
			t.Errorf("%s answered 200", path)
		}
	}
}

// club-page.test.mjs runs the script against a hand-written shell; this checks the real one carries every id the
// script reads, so the two cannot drift apart.
func TestClubPageShellHasWhatTheScriptReads(t *testing.T) {
	c := newClubHarness(t)
	k := deriveClub(t, secretK(10))
	_, _, body := c.page("/c/"+k.id, pageUserAgent)
	for _, want := range []string{`<main id="club" data-club="` + k.id + `">`, `<p id="status" role="status">If the button does not appear`, `<a id="open" class="button" href="spokenmargins://club" hidden>`} {
		if !strings.Contains(body, want) {
			t.Errorf("the shell lacks %s", want)
		}
	}
	script, err := os.ReadFile("../clubs/club-page.mjs")
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"club", "status", "open"} {
		if !bytes.Contains(script, []byte(`getElementById('`+id+`')`)) {
			t.Errorf("the script no longer reads #%s", id)
		}
	}
}

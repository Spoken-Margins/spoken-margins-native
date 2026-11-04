package api_test

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"spokenmargins.dev/bridge/internal/api"
	"spokenmargins.dev/bridge/internal/client"
	"spokenmargins.dev/bridge/internal/config"
	"spokenmargins.dev/bridge/internal/links"
	"spokenmargins.dev/bridge/internal/reportrules"
	"spokenmargins.dev/bridge/internal/reports"
	"spokenmargins.dev/bridge/internal/senders"
)

// senderRig is the attested harness with links, reports and the sender ledger wired in, and one
// registered install. The clock is the test's own: the server and the client both read it.
type senderRig struct {
	*harness
	c   *client.Client
	now time.Time
}

func newSenderRig(t *testing.T) *senderRig {
	t.Helper()
	h := newHarness(t)
	r := &senderRig{harness: h, now: time.Now().UTC().Truncate(time.Second)}
	ls, err := links.OpenStore(filepath.Join(h.stateDir, "links"))
	if err != nil {
		t.Fatal(err)
	}
	rs, err := reports.Open(filepath.Join(h.stateDir, "reports"))
	if err != nil {
		t.Fatal(err)
	}
	ss, err := senders.Open(filepath.Join(h.stateDir, "senders"))
	if err != nil {
		t.Fatal(err)
	}
	h.srv.Links, h.srv.Reports, h.srv.Senders = ls, rs, ss
	h.srv.LinkInstallURL = "https://testflight.apple.com/join/fixture"
	h.srv.RequestsPerInstallPerHr = 500
	h.srv.Now = func() time.Time { return r.now }
	if _, err := config.Set(h.configPath, config.ServiceLinks, true); err != nil {
		t.Fatal(err)
	}
	r.c = h.client()
	r.c.Now = func() time.Time { return r.now }
	if resp, err := r.c.Register(); err != nil || resp.Status != 201 {
		t.Fatalf("register: %v %v", resp, err)
	}
	return r
}

// check is the sender's attested check.
func (r *senderRig) check(t *testing.T) client.Response {
	t.Helper()
	resp, err := r.c.Attested(api.PathLinkSender, nil)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

// permit asks for a permit and fails the test if there is none.
func (r *senderRig) permit(t *testing.T) string {
	t.Helper()
	resp := r.check(t)
	p, _ := resp.Body["permit"].(string)
	if resp.Status != 200 || !regexp.MustCompile(`^[0-9a-f]{32}$`).MatchString(p) {
		t.Fatalf("no permit: %s", resp)
	}
	return p
}

// upload posts a link; an empty permit sends no header. It returns the status, the link id and the error code.
func (r *senderRig) upload(t *testing.T, permit string) (int, string, string) {
	t.Helper()
	data, ct := multipartLink(t, [][2][]byte{{[]byte("packet"), linkPacket}, {[]byte("preview"), linkPreview}})
	req, _ := http.NewRequest("POST", r.http.URL+api.PathLinks, bytes.NewReader(data))
	req.Header.Set("Content-Type", ct)
	if permit != "" {
		req.Header.Set(api.HeaderLinkPermit, permit)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	m := regexp.MustCompile(`"id":"([0-9a-f]{32})"`).FindStringSubmatch(string(body))
	id := ""
	if m != nil {
		id = m[1]
	}
	code := ""
	if m := regexp.MustCompile(`"error":"([a-z_]+)"`).FindStringSubmatch(string(body)); m != nil {
		code = m[1]
	}
	return resp.StatusCode, id, code
}

func (r *senderRig) permitted(t *testing.T) string {
	t.Helper()
	status, id, code := r.upload(t, r.permit(t))
	if status != 201 || id == "" {
		t.Fatalf("permitted upload: %d %s", status, code)
	}
	return id
}

func (r *senderRig) report(t *testing.T, id, category string) {
	t.Helper()
	form := url.Values{"category": {category}}
	if category == "abuse_material" {
		form.Set("link", "https://spokenmargins.com/l/"+id+"#"+reportKey)
	}
	resp, err := http.PostForm(r.http.URL+"/l/"+id+"/report", form)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("report %s: %d", category, resp.StatusCode)
	}
}

func fileCount(dir string) int {
	n := 0
	filepath.WalkDir(dir, func(p string, d os.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			n++
		}
		return nil
	})
	return n
}

func TestTheSenderCheckNeedsAttestationAndOffersAPermit(t *testing.T) {
	r := newSenderRig(t)
	plain, err := http.Post(r.http.URL+api.PathLinkSender, "application/json", nil)
	if err != nil {
		t.Fatal(err)
	}
	plain.Body.Close()
	if plain.StatusCode != 401 {
		t.Fatalf("unattested: %d", plain.StatusCode)
	}
	resp := r.check(t)
	if resp.Status != 200 || resp.Body["sharingAllowed"] != true || resp.Body["sharingEnded"] != false || resp.Body["notice"] != nil || resp.Body["sharingPausedUntil"] != nil {
		t.Fatalf("a sender nobody reported: %s", resp)
	}
	if resp.Body["permit"] == nil || resp.Body["permitExpiresAt"] == nil {
		t.Fatalf("no permit: %s", resp)
	}
	if fileCount(filepath.Join(r.stateDir, "senders", "senders")) != 0 {
		t.Fatal("asking for a permit must not create a sender file")
	}
}

func TestAPermitIsSpentByOneUploadAndOnlyAGoodOneIsAccepted(t *testing.T) {
	r := newSenderRig(t)
	p := r.permit(t)
	if status, id, code := r.upload(t, p); status != 201 || id == "" {
		t.Fatalf("first use: %d %s", status, code)
	}
	if status, _, code := r.upload(t, p); status != 403 || code != "bad_permit" {
		t.Fatalf("second use: %d %s", status, code)
	}
	if status, _, code := r.upload(t, strings.Repeat("0", 32)); status != 403 || code != "bad_permit" {
		t.Fatalf("made-up permit: %d %s", status, code)
	}
	// Not required yet: the app that exists today keeps working, unattributed.
	if status, id, _ := r.upload(t, ""); status != 201 || id == "" {
		t.Fatalf("no permit while optional: %d", status)
	}
	// A permit lasts ten minutes.
	old := r.permit(t)
	r.now = r.now.Add(10 * time.Minute)
	if status, _, code := r.upload(t, old); status != 403 || code != "bad_permit" {
		t.Fatalf("stale permit: %d %s", status, code)
	}
}

func TestAnUploadWithoutAPermitIsRefusedOnceTheServerRequiresOne(t *testing.T) {
	r := newSenderRig(t)
	r.srv.RequireLinkPermit = true
	if status, id, code := r.upload(t, ""); status != 403 || code != "permit_required" || id != "" {
		t.Fatalf("no permit: %d %s", status, code)
	}
	if status, _, _ := r.upload(t, r.permit(t)); status != 201 {
		t.Fatalf("with a permit: %d", status)
	}
	r.srv.Senders = nil
	if status, _, code := r.upload(t, ""); status != 503 || code != "disabled" {
		t.Fatalf("no ledger: %d %s", status, code)
	}
}

func TestOnePermitCannotMakeTwoLinksWhenTwoUploadsRace(t *testing.T) {
	r := newSenderRig(t)
	p := r.permit(t)
	var wg sync.WaitGroup
	var mu sync.Mutex
	made := 0
	for i := 0; i < 6; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			status, _, _ := r.upload(t, p)
			mu.Lock()
			if status == 201 {
				made++
			}
			mu.Unlock()
		}()
	}
	wg.Wait()
	if made != 1 {
		t.Fatalf("%d links from one permit", made)
	}
}

func TestTwoReportedLinksPauseTheSenderAndTheNoticeIsTheSameForEveryCategory(t *testing.T) {
	r := newSenderRig(t)
	first, second := r.permitted(t), r.permitted(t)
	stale := r.permit(t) // asked before the strike

	r.report(t, first, "harassment")
	one := r.check(t)
	if one.Body["notice"] != reportrules.SenderNotice || one.Body["sharingAllowed"] != true || one.Body["sharingPausedUntil"] != nil {
		t.Fatalf("after one reported link: %s", one)
	}
	if again := r.check(t); again.Body["notice"] != nil {
		t.Fatalf("the notice is shown once: %s", again)
	}

	r.report(t, second, "abuse_material")
	two := r.check(t)
	if two.Body["notice"] != reportrules.SenderNotice {
		t.Fatalf("an abuse-material report must read like any other: %s", two)
	}
	if two.Body["sharingAllowed"] != false || two.Body["permit"] != nil {
		t.Fatalf("a strike pauses sharing: %s", two)
	}
	until, _ := time.Parse(time.RFC3339, two.Body["sharingPausedUntil"].(string))
	if !until.Equal(r.now.Add(7 * 24 * time.Hour)) {
		t.Fatalf("strike 1 pauses a week: %v", two.Body["sharingPausedUntil"])
	}
	// The owner's notice says "after a report"; nothing else may mention one, or its category.
	answers := strings.ReplaceAll(one.String()+two.String(), reportrules.SenderNotice, "")
	for _, banned := range []string{"harassment", "abuse", "categor", "report"} {
		if strings.Contains(strings.ToLower(answers), banned) {
			t.Errorf("the sender's answer names %q", banned)
		}
	}

	// A permit asked for before the strike no longer works.
	if status, _, code := r.upload(t, stale); status != 403 || code != "sharing_paused" {
		t.Fatalf("stale permit during a pause: %d %s", status, code)
	}
	// A week later the pause is over.
	r.now = r.now.Add(7 * 24 * time.Hour)
	if after := r.check(t); after.Body["sharingAllowed"] != true || after.Body["permit"] == nil {
		t.Fatalf("after the week: %s", after)
	}
}

func TestTheLadderEndsLinkSharingForGoodAfterThreeStrikes(t *testing.T) {
	r := newSenderRig(t)
	r.srv.ReportRules = reportrules.Config{
		ReasonWindow: 7 * 24 * time.Hour, ReasonFromNth: 2,
		StrikeLinks: 1, StrikeWindow: 90 * 24 * time.Hour,
		PauseAfterStrike1: time.Second, PauseAfterStrike2: time.Second,
	}
	for strike := 1; strike <= 3; strike++ {
		r.report(t, r.permitted(t), "other")
		r.now = r.now.Add(2 * time.Second)
	}
	end := r.check(t)
	if end.Body["sharingEnded"] != true || end.Body["sharingAllowed"] != false || end.Body["permit"] != nil || end.Body["sharingPausedUntil"] != nil {
		t.Fatalf("after strike 3: %s", end)
	}
	r.now = r.now.Add(5 * 365 * 24 * time.Hour)
	if later := r.check(t); later.Body["sharingEnded"] != true || later.Body["permit"] != nil {
		t.Fatalf("permanent means permanent: %s", later)
	}
}

func TestAReportOfALinkMadeWithoutAPermitCountsAgainstNobody(t *testing.T) {
	r := newSenderRig(t)
	status, id, _ := r.upload(t, "")
	if status != 201 {
		t.Fatalf("upload: %d", status)
	}
	r.report(t, id, "harassment")
	if !linkIsDown(r.srv.Handler(), id) {
		t.Fatal("the report must still take the link down")
	}
	if fileCount(filepath.Join(r.stateDir, "senders", "senders")) != 0 || fileCount(filepath.Join(r.stateDir, "senders", "bindings")) != 0 {
		t.Fatal("an unattributed link left a sender trail")
	}
}

func TestTheLedgerHoldsNoInstallKeyCategoryOrLinkKey(t *testing.T) {
	r := newSenderRig(t)
	a, b := r.permitted(t), r.permitted(t)
	r.report(t, a, "harassment")
	r.report(t, b, "abuse_material")
	keyID := r.c.Device.KeyID
	banned := []string{string(keyID), hex.EncodeToString(keyID), base64.StdEncoding.EncodeToString(keyID), "harassment", "abuse_material", reportKey}
	for path, data := range everythingUnder(t, filepath.Join(r.stateDir, "senders")) {
		if filepath.Base(path) == "key" {
			continue
		}
		for _, bad := range banned {
			if bytes.Contains(data, []byte(bad)) {
				t.Errorf("%s holds %q", path, bad)
			}
		}
	}
	if fileCount(filepath.Join(r.stateDir, "senders", "bindings")) != 2 || fileCount(filepath.Join(r.stateDir, "senders", "senders")) != 1 {
		t.Fatal("expected two ties and one sender")
	}
}

func TestTwoInstallsAreTwoSenders(t *testing.T) {
	r := newSenderRig(t)
	a, b := r.permitted(t), r.permitted(t)
	other := r.harness.client()
	other.Now = r.c.Now
	if resp, err := other.Register(); err != nil || resp.Status != 201 {
		t.Fatalf("register: %v %v", resp, err)
	}
	r.report(t, a, "other")
	r.report(t, b, "other") // strike for the first install
	resp, err := other.Attested(api.PathLinkSender, nil)
	if err != nil || resp.Status != 200 || resp.Body["sharingAllowed"] != true || resp.Body["notice"] != nil {
		t.Fatalf("another install is untouched: %v %v", resp, err)
	}
}

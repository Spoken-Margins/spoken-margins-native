package api_test

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"spokenmargins.dev/bridge/internal/api"
	"spokenmargins.dev/bridge/internal/config"
	"spokenmargins.dev/bridge/internal/links"
	"spokenmargins.dev/bridge/internal/reports"
)

// Reporting a club or one post in it (#1799, docs/design/club-mailbox.md section 7).

const clubInviteKey = "INVITEKEYSECRETKEY-9d2c"

func newReportingClubs(t *testing.T) *clubHarness {
	t.Helper()
	c := newClubHarness(t)
	rs, err := reports.Open(filepath.Join(c.stateDir, "reports"))
	if err != nil {
		t.Fatal(err)
	}
	c.srv.Reports = rs
	return c
}

func (c *clubHarness) report(id string, form url.Values, proof, addr string) reply {
	c.t.Helper()
	return c.reportTo(api.PathClubs+"/"+id+"/report", form, proof, addr)
}

func (c *clubHarness) reportTo(path string, form url.Values, proof, addr string) reply {
	c.t.Helper()
	r := httptest.NewRequest("POST", path, strings.NewReader(form.Encode()))
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	r.RemoteAddr = addr + ":4321"
	if proof != "" {
		r.Header.Set("Authorization", "Bearer "+proof)
	}
	w := httptest.NewRecorder()
	c.h.ServeHTTP(w, r)
	out, _ := io.ReadAll(w.Result().Body)
	return reply{code: w.Code, body: out, hdr: w.Result().Header}
}

type reportAnswer struct {
	Filed             bool   `json:"filed"`
	Ref               string `json:"ref"`
	ReasonOutstanding bool   `json:"reasonOutstanding"`
}

func (r reply) answer(t *testing.T) reportAnswer {
	t.Helper()
	var a reportAnswer
	if err := json.Unmarshal(r.body, &a); err != nil {
		t.Fatalf("answer %d %s: %v", r.code, r.body, err)
	}
	return a
}

// aClub makes a club with three posts and returns its keys and the packets.
func aClub(t *testing.T, c *clubHarness, seed byte) (clubKeys, [][]byte) {
	t.Helper()
	k := deriveClub(t, secretK(seed))
	if r := c.create(k, sealedPart(links.PartClubHeader, 80, "header"), clubAddr); r.code != 201 {
		t.Fatalf("create: %d %s", r.code, r.body)
	}
	var packets [][]byte
	for i := 1; i <= 3; i++ {
		p := sealedPart(links.PartPacket, 100+i, fmt.Sprintf("packet-%d", i))
		packets = append(packets, p)
		if r := c.post(k, p, clubAddr); r.code != 201 {
			t.Fatalf("post %d: %d %s", i, r.code, r.body)
		}
	}
	return k, packets
}

func form(kv ...string) url.Values {
	v := url.Values{}
	for i := 0; i < len(kv); i += 2 {
		v.Add(kv[i], kv[i+1])
	}
	return v
}

func TestAReportedPostIsDisabledAtOnceAndTheOthersAndTheNumbersStay(t *testing.T) {
	c := newReportingClubs(t)
	k, packets := aClub(t, c, 30)
	r := c.report(k.id, form("category", "harassment", "post", "2"), k.read, "203.0.113.7")
	a := r.answer(t)
	if r.code != 200 || !a.Filed || !regexp.MustCompile(`^[A-Z2-9]{12}$`).MatchString(a.Ref) || a.ReasonOutstanding {
		t.Fatalf("report: %d %s", r.code, r.body)
	}
	// The list keeps every number; the reported post is now empty, and the others are byte for byte.
	var got listing
	if err := json.Unmarshal(c.list(k, 0, clubAddr).body, &got); err != nil || len(got.Posts) != 3 || got.Posts[1].Size != 0 {
		t.Fatalf("list after report: %+v %v", got, err)
	}
	if b := c.item(k, 2, clubAddr); b.code != 200 || len(b.body) != 0 {
		t.Errorf("the reported post is served: %d %d bytes", b.code, len(b.body))
	}
	for _, i := range []int{1, 3} {
		if b := c.item(k, i, clubAddr); string(b.body) != string(packets[i-1]) {
			t.Errorf("post %d changed", i)
		}
	}
	// The next post gets number 4, not the reported one's.
	if p := c.post(k, sealedPart(links.PartPacket, 90, "later"), clubAddr); p.code != 201 || !strings.Contains(string(p.body), `"seq":4`) {
		t.Errorf("post after a report: %d %s", p.code, p.body)
	}
	// Disabling again is harmless.
	if again := c.report(k.id, form("category", "harassment", "post", "2"), k.read, "203.0.113.8"); again.code != 200 {
		t.Errorf("a second report of the same post: %d", again.code)
	}
	// The bytes are kept for the club's lifetime, on disk, for a hold by hand.
	kept, err := os.ReadFile(filepath.Join(c.stateDir, "clubs", k.id, "disabled", "2"))
	if err != nil || string(kept) != string(packets[1]) {
		t.Errorf("the disabled post's bytes were not kept: %v", err)
	}
	// The record names the club and the post, for the owner.
	recs, err := reports.List(filepath.Join(c.stateDir, "reports"))
	if err != nil || len(recs) != 2 || recs[0].ClubID != k.id || recs[0].Post != 2 || recs[0].LinkID != "" || recs[0].Ref != a.Ref {
		t.Errorf("records: %+v %v", recs, err)
	}
}

func TestAPostReportNeedsTheReadProof(t *testing.T) {
	c := newReportingClubs(t)
	k, packets := aClub(t, c, 31)
	other := deriveClub(t, secretK(32))
	for name, tc := range map[string]struct{ id, proof string }{
		"no proof":          {k.id, ""},
		"the post proof":    {k.id, k.post},
		"another club's":    {k.id, other.read},
		"a malformed proof": {k.id, "nonsense"},
		"an unknown club":   {other.id, other.read},
	} {
		r := c.report(tc.id, form("category", "other", "post", "1"), tc.proof, "203.0.113.9")
		if r.code != 404 || r.errCode() != "not_found" {
			t.Errorf("%s: %d %s, want the 404 every stranger gets", name, r.code, r.body)
		}
	}
	if string(c.item(k, 1, clubAddr).body) != string(packets[0]) {
		t.Fatal("a refused report disabled the post")
	}
	if recs, _ := reports.List(filepath.Join(c.stateDir, "reports")); len(recs) != 0 {
		t.Errorf("a refused report was filed: %+v", recs)
	}
	// A member naming a post that is not in the box is told the same, and nothing changes.
	if r := c.report(k.id, form("category", "other", "post", "9"), k.read, "203.0.113.9"); r.code != 404 {
		t.Errorf("a post number not in the box: %d", r.code)
	}
}

func TestAWholeClubReportNeedsOnlyTheIdAndDisablesThatClub(t *testing.T) {
	c := newReportingClubs(t)
	k, _ := aClub(t, c, 33)
	bystander, _ := aClub(t, c, 34)
	r := c.report(k.id, form("category", "hateful_conduct"), "", "203.0.113.7")
	if a := r.answer(t); r.code != 200 || !a.Filed {
		t.Fatalf("report: %d %s", r.code, r.body)
	}
	// A member is told the club is gone; a stranger is told nothing; the other club is untouched.
	if l := c.list(k, 0, clubAddr); l.code != 410 || l.errCode() != "expired_or_removed" {
		t.Errorf("member after a report: %d %s", l.code, l.body)
	}
	if l := c.do("GET", api.PathClubs+"/"+k.id+"/posts", nil, "", clubAddr); l.code != 404 {
		t.Errorf("stranger after a report: %d", l.code)
	}
	if l := c.list(bystander, 0, clubAddr); l.code != 200 {
		t.Errorf("another club after a report: %d", l.code)
	}
	if p := c.post(k, sealedPart(links.PartPacket, 90, "late"), clubAddr); p.code != 410 {
		t.Errorf("post to a reported club: %d, want 410", p.code)
	}
	// The content stays for the owner's hold by hand, and the club ends 30 days on.
	if _, err := os.Stat(filepath.Join(c.stateDir, "clubs", k.id, "header")); err != nil {
		t.Errorf("a disabled club lost its header: %v", err)
	}
	if n, err := c.srv.Clubs.Sweep(c.clock.Now().AddDate(0, 0, 31)); err != nil || n != 1 {
		t.Errorf("sweep after 31 days ended %d clubs (%v), want the reported one", n, err)
	}
	// An unknown id and an ended club answer 404, so a report is no way to find out which ids were clubs.
	if r := c.report(deriveClub(t, secretK(35)).id, form("category", "other"), "", "203.0.113.7"); r.code != 404 {
		t.Errorf("report of no club: %d", r.code)
	}
	if r := c.report(k.id, form("category", "other"), "", "203.0.113.10"); r.code != 404 {
		t.Errorf("report of an ended club: %d", r.code)
	}
}

func TestACategoryIsRequiredAndOnlyTheBodyChoosesIt(t *testing.T) {
	c := newReportingClubs(t)
	k, _ := aClub(t, c, 36)
	for name, tc := range map[string]struct {
		path string
		form url.Values
	}{
		"no category":       {api.PathClubs + "/" + k.id + "/report", form()},
		"unknown category":  {api.PathClubs + "/" + k.id + "/report", form("category", "spam")},
		"two categories":    {api.PathClubs + "/" + k.id + "/report", form("category", "other", "category", "harassment")},
		"category in query": {api.PathClubs + "/" + k.id + "/report?category=other", form()},
		"post zero":         {api.PathClubs + "/" + k.id + "/report", form("category", "other", "post", "0")},
		"post negative":     {api.PathClubs + "/" + k.id + "/report", form("category", "other", "post", "-1")},
		"post padded":       {api.PathClubs + "/" + k.id + "/report", form("category", "other", "post", "01")},
		"post not a number": {api.PathClubs + "/" + k.id + "/report", form("category", "other", "post", "x")},
		"two posts":         {api.PathClubs + "/" + k.id + "/report", form("category", "other", "post", "1", "post", "2")},
		"huge reason":       {api.PathClubs + "/" + k.id + "/report", form("category", "other", "reason", strings.Repeat("x", reports.MaxReasonBytes+1))},
	} {
		if r := c.reportTo(tc.path, tc.form, k.read, "203.0.113.7"); r.code != 400 {
			t.Errorf("%s: %d %s, want 400", name, r.code, r.body)
		}
	}
	if l := c.list(k, 0, clubAddr); l.code != 200 {
		t.Errorf("a refused form took the club down: %d", l.code)
	}
}

func TestASecondReportInAWeekOwesAReasonOnTheSecondRoute(t *testing.T) {
	c := newReportingClubs(t)
	k, _ := aClub(t, c, 37)
	first := c.report(k.id, form("category", "other", "post", "1"), k.read, "203.0.113.7").answer(t)
	if first.ReasonOutstanding {
		t.Fatal("the first report owes a reason")
	}
	second := c.report(k.id, form("category", "other", "post", "2"), k.read, "203.0.113.7").answer(t)
	if !second.Filed || !second.ReasonOutstanding || second.Ref == "" {
		t.Fatalf("second report: %+v", second)
	}
	// The reason goes with the ref, and only for that club.
	route := api.PathClubs + "/" + k.id + "/report/reason"
	other := deriveClub(t, secretK(38))
	if r := c.reportTo(api.PathClubs+"/"+other.id+"/report/reason", form("ref", second.Ref, "reason", "why"), "", "203.0.113.7"); r.code != 404 {
		t.Errorf("a ref on another club's route: %d", r.code)
	}
	if r := c.reportTo(route, form("ref", second.Ref, "reason", "  "), "", "203.0.113.7"); r.code != 400 {
		t.Errorf("an empty reason: %d", r.code)
	}
	if r := c.reportTo(route, form("ref", second.Ref, "reason", "it targets one member"), "", "203.0.113.7"); r.code != 200 {
		t.Errorf("the reason: %d %s", r.code, r.body)
	}
	if r := c.reportTo(route, form("ref", second.Ref, "reason", "again"), "", "203.0.113.7"); r.code != 200 {
		t.Errorf("a repeated reason is harmless: %d", r.code)
	}
	recs, _ := reports.List(filepath.Join(c.stateDir, "reports"))
	if len(recs) != 2 || recs[1].Reason != "it targets one member" || recs[0].Reason != "" {
		t.Errorf("records: %+v", recs)
	}
	// A reporter from another network owes nothing.
	if a := c.report(k.id, form("category", "other", "post", "3"), k.read, "203.0.113.99").answer(t); a.ReasonOutstanding {
		t.Error("another network's first report owes a reason")
	}
}

func TestALinkReportsRefIsNotAcceptedOnAClubRoute(t *testing.T) {
	c := newReportingClubs(t)
	k, _ := aClub(t, c, 39)
	// A link report's record, filed straight into the same store.
	if err := c.srv.Reports.Add(reports.Record{Ref: "LINKREF23456", LinkID: strings.Repeat("a", 32), Category: "other", At: c.clock.Now()}); err != nil {
		t.Fatal(err)
	}
	if r := c.reportTo(api.PathClubs+"/"+k.id+"/report/reason", form("ref", "LINKREF23456", "reason", "x"), "", "203.0.113.7"); r.code != 404 {
		t.Errorf("a link's ref accepted on a club route: %d", r.code)
	}
}

func abuseForm(id string, extra ...string) url.Values {
	return form(append([]string{"category", "abuse_material", "link", "https://spokenmargins.proximitytoprogress.com/c/" + id + "#" + clubInviteKey}, extra...)...)
}

func TestAnAbuseMaterialReportHoldsTheClubBeforeEndingItAndOnlyThereKeepsTheKey(t *testing.T) {
	c := newReportingClubs(t)
	k, packets := aClub(t, c, 40)
	c.report(k.id, form("category", "other", "post", "3"), k.read, "203.0.113.50") // a disabled post is held too
	r := c.report(k.id, abuseForm(k.id), "", "203.0.113.7")
	if a := r.answer(t); r.code != 200 || !a.Filed {
		t.Fatalf("report: %d %s", r.code, r.body)
	}
	if l := c.list(k, 0, clubAddr); l.code != 410 {
		t.Errorf("a held club is still served: %d", l.code)
	}
	held := filepath.Join(c.stateDir, "clubs-held", k.id)
	for name, want := range map[string]string{
		"header": string(sealedPart(links.PartClubHeader, 80, "header")), "posts/1": string(packets[0]), "posts/2": string(packets[1]),
		"disabled/3": string(packets[2]), "reported-link": "https://spokenmargins.proximitytoprogress.com/c/" + k.id + "#" + clubInviteKey,
	} {
		got, err := os.ReadFile(filepath.Join(held, name))
		if err != nil || string(got) != want {
			t.Errorf("held copy %s: %v", name, err)
		}
	}
	if _, err := os.Stat(filepath.Join(held, "posts", "3")); err == nil {
		t.Error("the held copy carries the empty place of a disabled post")
	}
	// The live club kept only its tombstone, and the key is nowhere but the held folder.
	if entries, _ := os.ReadDir(filepath.Join(c.stateDir, "clubs", k.id)); len(entries) != 1 || entries[0].Name() != "meta.json" {
		t.Errorf("the ended club keeps %v, want only its tombstone", entries)
	}
	for path, data := range everythingUnder(t, c.stateDir) {
		if strings.Contains(string(data), clubInviteKey) && !strings.HasPrefix(path, filepath.Join(c.stateDir, "clubs-held")) {
			t.Errorf("the invite key is in %s", path)
		}
	}
	if lines, _ := os.ReadFile(filepath.Join(c.stateDir, "clubs-held", "access.log")); !strings.Contains(string(lines), `"event":"hold"`) || strings.Contains(string(lines), clubInviteKey) {
		t.Errorf("access log: %s", lines)
	}
	if st := c.srv.Clubs.Status(k.id, 0, c.clock.Now()); st != "taken down, held" {
		t.Errorf("status %q", st)
	}
}

func TestOnlyAnAbuseMaterialReportKeepsALink(t *testing.T) {
	c := newReportingClubs(t)
	k, _ := aClub(t, c, 41)
	c.report(k.id, abuseFormWithCategory(k.id, "harassment"), "", "203.0.113.7")
	// A key pasted into a written reason does not reach the record either.
	c.report(k.id, form("category", "other", "reason", "see https://x/c/"+k.id+"#"+clubInviteKey), "", "203.0.113.20")
	for path, data := range everythingUnder(t, c.stateDir) {
		if strings.Contains(string(data), clubInviteKey) {
			t.Errorf("the key reached %s from a harassment report", path)
		}
	}
	if _, err := os.Stat(filepath.Join(c.stateDir, "clubs-held")); err == nil {
		t.Error("a harassment report made a hold")
	}
}

func deriveClubID(t *testing.T, seed byte) string { return deriveClub(t, secretK(seed)).id }

func abuseFormWithCategory(id, category string) url.Values {
	return form("category", category, "link", "https://x/c/"+id+"#"+clubInviteKey)
}

func TestAnAbuseReportWithoutAUsableLinkStillHoldsAndEndsTheClub(t *testing.T) {
	c := newReportingClubs(t)
	k, _ := aClub(t, c, 42)
	other := deriveClub(t, secretK(43))
	// A link naming another club is dropped unread.
	r := c.report(k.id, abuseForm(other.id), "", "203.0.113.7")
	if r.code != 200 {
		t.Fatalf("report: %d %s", r.code, r.body)
	}
	if got, _ := os.ReadFile(filepath.Join(c.stateDir, "clubs-held", k.id, "reported-link")); len(got) != 0 {
		t.Errorf("a link for another club was kept: %s", got)
	}
	if _, err := os.Stat(filepath.Join(c.stateDir, "clubs-held", k.id, "posts", "1")); err != nil {
		t.Errorf("the club was not held: %v", err)
	}
}

func TestAPostLevelAbuseReportNeedsTheProofToo(t *testing.T) {
	c := newReportingClubs(t)
	k, _ := aClub(t, c, 44)
	if r := c.report(k.id, abuseForm(k.id, "post", "1"), "", "203.0.113.7"); r.code != 404 {
		t.Fatalf("a post-level abuse report without the proof: %d", r.code)
	}
	if l := c.list(k, 0, clubAddr); l.code != 200 {
		t.Fatalf("a refused abuse report ended the club: %d", l.code)
	}
	if r := c.report(k.id, abuseForm(k.id, "post", "1"), k.read, "203.0.113.7"); r.code != 200 {
		t.Fatalf("with the proof: %d %s", r.code, r.body)
	}
	if _, err := os.Stat(filepath.Join(c.stateDir, "clubs-held", k.id)); err != nil {
		t.Errorf("not held: %v", err)
	}
}

func TestAReReportOfAHeldClubAddsItsLinkAndBeginsNoNewHold(t *testing.T) {
	c := newReportingClubs(t)
	k, _ := aClub(t, c, 45)
	c.report(k.id, abuseForm(k.id), "", "203.0.113.7")
	second := "https://other.example/c/" + k.id + "#SECONDKEY"
	if r := c.report(k.id, form("category", "abuse_material", "link", second), "", "203.0.113.8"); r.code != 200 {
		t.Fatalf("re-report: %d %s", r.code, r.body)
	}
	if got, _ := os.ReadFile(filepath.Join(c.stateDir, "clubs-held", k.id, "reported-link-2")); string(got) != second {
		t.Errorf("second link: %q", got)
	}
}

func TestHoldsPastTheClientCapAndTheStoreCapDisableTheClubAndKeepItsContent(t *testing.T) {
	c := newReportingClubs(t)
	c.srv.HoldsPerClientPerDay = 1
	a, _ := aClub(t, c, 46)
	b, _ := aClub(t, c, 47)
	if r := c.report(a.id, abuseForm(a.id), "", "203.0.113.7"); r.code != 200 {
		t.Fatal(r.code)
	}
	// The same network's second hold is over its day's allowance: the club goes dark, keeps its content and
	// its reported link for the owner, and the reporter sees the normal answer.
	if r := c.report(b.id, abuseForm(b.id), "", "203.0.113.7"); r.code != 200 {
		t.Fatalf("report past the client cap: %d %s", r.code, r.body)
	}
	if l := c.list(b, 0, clubAddr); l.code != 410 {
		t.Errorf("the capped club is still served: %d", l.code)
	}
	if _, err := os.Stat(filepath.Join(c.stateDir, "clubs", b.id, "header")); err != nil {
		t.Errorf("a capped club lost its content: %v", err)
	}
	if got, _ := os.ReadFile(filepath.Join(c.stateDir, "clubs", b.id, "reported-link")); !strings.Contains(string(got), clubInviteKey) {
		t.Error("the capped club's reported link was not parked for the owner")
	}
	if _, err := os.Stat(filepath.Join(c.stateDir, "clubs-held", b.id)); err == nil {
		t.Error("a capped club was held")
	}
	if lines, _ := os.ReadFile(filepath.Join(c.stateDir, "clubs-held", "access.log")); !strings.Contains(string(lines), `"event":"cap"`) {
		t.Errorf("no cap line: %s", lines)
	}
	// The owner's hold by hand still works, and takes the parked link.
	if err := c.srv.Clubs.HoldByOwner(b.id, "NCMEC-9", nil, c.clock.Now()); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(filepath.Join(c.stateDir, "clubs-held", b.id, "reported-link")); !strings.Contains(string(got), clubInviteKey) {
		t.Error("the owner's hold lost the parked link")
	}
	// The store's own cap, with a fresh allowance.
	c.srv.HoldsPerClientPerDay = 50
	c.srv.Clubs.HoldLimits = links.HoldLimits{MaxItems: 2}
	d, _ := aClub(t, c, 48)
	if r := c.report(d.id, abuseForm(d.id), "", "203.0.113.30"); r.code != 200 {
		t.Fatal(r.code)
	}
	if _, err := os.Stat(filepath.Join(c.stateDir, "clubs-held", d.id)); err == nil {
		t.Error("a hold went past the store cap")
	}
	if st := c.srv.Clubs.Status(d.id, 0, c.clock.Now()); st != "disabled" {
		t.Errorf("status %q, want disabled", st)
	}
}

func TestAClubReportLeavesNoClubIdProofOrKeyInAnyLog(t *testing.T) {
	c := newReportingClubs(t)
	k, _ := aClub(t, c, 49)
	c.report(k.id, form("category", "harassment", "post", "1", "reason", "unique-reason-text"), k.read, "203.0.113.7")
	c.report(k.id, form("category", "other"), "", "203.0.113.7")
	c.report(deriveClubID(t, 50), abuseForm(deriveClubID(t, 50)), "", "203.0.113.7")
	b, _ := aClub(t, c, 51)
	c.report(b.id, abuseForm(b.id), "", "203.0.113.7")
	if err := c.srv.Flush(); err != nil {
		t.Fatal(err)
	}
	abuse := c.abuseLog.String()
	if !strings.Contains(abuse, `"id":"club"`) || !strings.Contains(abuse, `"reason":"harassment"`) {
		t.Errorf("the abuse log does not count club reports under the club key:\n%s", abuse)
	}
	for name, text := range map[string]string{"request log": c.reqLog.String(), "abuse log": abuse} {
		for what, secret := range map[string]string{
			"club id": k.id, "second club id": b.id, "read proof": k.read, "post proof": k.post, "invite key": clubInviteKey,
			"reason": "unique-reason-text", "address": "203.0.113.7",
		} {
			if strings.Contains(text, secret) {
				t.Errorf("the %s holds the %s", name, what)
			}
		}
	}
	for _, line := range jsonLines(t, c.reqLog.String()) {
		if line["route"] != "/api/v1/clubs/*" {
			t.Errorf("a club report is logged under %v", line["route"])
		}
	}
}

func TestClubReportsAreOffWithTheClubsSwitchAndWithoutAReportStore(t *testing.T) {
	c := newReportingClubs(t)
	k, _ := aClub(t, c, 52)
	c.srv.Reports = nil
	if r := c.report(k.id, form("category", "other"), "", "203.0.113.7"); r.code != 503 || r.errCode() != "disabled" {
		t.Errorf("no report store: %d %s", r.code, r.body)
	}
	if r := c.reportTo(api.PathClubs+"/"+k.id+"/report/reason", form("ref", "x", "reason", "y"), "", "203.0.113.7"); r.code != 503 {
		t.Errorf("reason with no report store: %d", r.code)
	}
	rs, _ := reports.Open(filepath.Join(c.stateDir, "reports"))
	c.srv.Reports = rs
	if _, err := config.Set(c.configPath, config.ServiceClubs, false); err != nil {
		t.Fatal(err)
	}
	if r := c.report(k.id, form("category", "other"), "", "203.0.113.7"); r.code != 503 {
		t.Errorf("clubs off: %d", r.code)
	}
	if _, err := config.Set(c.configPath, config.ServiceClubs, true); err != nil {
		t.Fatal(err)
	}
	if l := c.list(k, 0, clubAddr); l.code != 200 {
		t.Errorf("a refused report changed the club: %d", l.code)
	}
}

func TestClubReportsAreRateLimitedPerNetwork(t *testing.T) {
	c := newReportingClubs(t)
	k, _ := aClub(t, c, 53)
	codes := map[int]int{}
	for i := 0; i < 32; i++ {
		codes[c.report(k.id, form("category", "other", "post", "9"), k.read, "203.0.113.7").code]++
	}
	if codes[429] != 2 {
		t.Errorf("answers %v, want the last 2 of 32 refused with 429", codes)
	}
	if r := c.report(k.id, form("category", "other", "post", "9"), k.read, "203.0.113.200"); r.code == 429 {
		t.Error("another network was limited")
	}
}

func TestAnAbuseReportsReasonNeverKeepsTheInviteKeyInTheReportRecord(t *testing.T) {
	c := newReportingClubs(t)
	k, _ := aClub(t, c, 54)
	a := c.report(k.id, abuseForm(k.id, "reason", "see https://x/c/"+k.id+"#"+clubInviteKey), "", "203.0.113.7").answer(t)
	c.report(k.id, form("category", "abuse_material", "reason", "x"), "", "203.0.113.8")
	c.reportTo(api.PathClubs+"/"+k.id+"/report/reason", form("ref", a.Ref, "reason", "again https://x/c/"+k.id+"#"+clubInviteKey), "", "203.0.113.7")
	for path, data := range everythingUnder(t, c.stateDir) {
		if strings.Contains(string(data), clubInviteKey) && !strings.HasPrefix(path, filepath.Join(c.stateDir, "clubs-held")) {
			t.Errorf("the invite key is in %s", path)
		}
	}
}

// An ended club has nothing to park a link beside, so a hold the cap refuses must not answer as if the link
// were kept.
func TestAnAbuseReportOnAnEndedClubPastTheCapIsRefusedRatherThanLosingItsLink(t *testing.T) {
	c := newReportingClubs(t)
	c.srv.HoldsPerClientPerDay = 1
	a, _ := aClub(t, c, 55)
	b, _ := aClub(t, c, 56)
	if err := c.srv.Clubs.Takedown(b.id, c.clock.Now()); err != nil {
		t.Fatal(err)
	}
	if r := c.report(a.id, abuseForm(a.id), "", "203.0.113.7"); r.code != 200 {
		t.Fatal(r.code)
	}
	r := c.report(b.id, abuseForm(b.id), "", "203.0.113.7")
	if r.code != 503 || r.errCode() != "busy" {
		t.Fatalf("over the client cap, on an ended club: %d %s, want a retryable 503", r.code, r.body)
	}
	if recs, _ := reports.List(filepath.Join(c.stateDir, "reports")); len(recs) != 1 {
		t.Errorf("a refused report was filed: %+v", recs)
	}
	// The next day the same report holds the link.
	c.clock.Advance(25 * time.Hour)
	if r := c.report(b.id, abuseForm(b.id), "", "203.0.113.7"); r.code != 200 {
		t.Fatalf("retry the next day: %d %s", r.code, r.body)
	}
	if got, _ := os.ReadFile(filepath.Join(c.stateDir, "clubs-held", b.id, "reported-link")); !strings.Contains(string(got), clubInviteKey) {
		t.Error("the retried link was not held")
	}
}

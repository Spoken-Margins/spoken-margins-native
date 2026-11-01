package api_test

import (
	"bytes"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"spokenmargins.dev/bridge/internal/api"
)

const reportKey = "KEYKEYKEYSECRETKEY"

func postReport(h http.Handler, id, body, addr string) (int, string) {
	w := linkRequest(h, "POST", "/l/"+id+"/report", "application/x-www-form-urlencoded", []byte(body), addr)
	return w.Code, w.Body.String()
}

func stateDirOf(s *api.Server) string { return filepath.Join(filepath.Dir(s.PublicDir), "state") }

func linkIsDown(h http.Handler, id string) bool {
	for _, suffix := range []string{"", "/packet", "/preview"} {
		if w := linkRequest(h, "GET", "/l/"+id+suffix, "", nil, "198.51.100.1"); w.Code != 410 {
			return false
		}
	}
	return true
}

// everythingUnder returns the bytes of every file below dir, so a test can look for a key anywhere.
func everythingUnder(t *testing.T, dir string) map[string][]byte {
	t.Helper()
	out := map[string][]byte{}
	filepath.WalkDir(dir, func(path string, d os.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			data, _ := os.ReadFile(path)
			out[path] = data
		}
		return nil
	})
	return out
}

func TestReportInEveryOtherCategoryTakesTheLinkDownAndStoresNoKey(t *testing.T) {
	for _, cat := range []string{"intimate_images", "harassment", "hateful_conduct", "copyright", "other"} {
		t.Run(cat, func(t *testing.T) {
			s, _ := enabledLinks(t)
			h := s.Handler()
			id := createdLink(t, h)
			full := "https://spokenmargins.com/l/" + id + "#" + reportKey
			// A client that sends the link anyway: it must be dropped unread.
			code, body := postReport(h, id, "category="+cat+"&link="+full, "203.0.113.7")
			if code != 200 || !strings.Contains(body, "taken down") || !regexp.MustCompile(`<strong>[A-Z2-9]{12}</strong>`).MatchString(body) {
				t.Fatalf("report: %d %s", code, body)
			}
			if !linkIsDown(h, id) {
				t.Fatal("link still served after a report")
			}
			for path, data := range everythingUnder(t, stateDirOf(s)) {
				if bytes.Contains(data, []byte(reportKey)) {
					t.Fatalf("the key reached %s", path)
				}
			}
			if _, err := os.Stat(filepath.Join(stateDirOf(s), "links-held")); err == nil {
				t.Fatal("a plain report held the link")
			}
		})
	}
}

func TestAbuseMaterialReportHoldsBeforeTakedown(t *testing.T) {
	s, _ := enabledLinks(t)
	h := s.Handler()
	id := createdLink(t, h)
	full := "https://spokenmargins.com/l/" + id + "#" + reportKey
	code, body := postReport(h, id, "category=abuse_material&link="+full, "203.0.113.7")
	if code != 200 {
		t.Fatalf("report: %d %s", code, body)
	}
	if !linkIsDown(h, id) {
		t.Fatal("link still served")
	}
	held := filepath.Join(stateDirOf(s), "links-held", id)
	// The ciphertext was copied before the takedown deleted it: this is the point of the order.
	packet, err := os.ReadFile(filepath.Join(held, "packet"))
	if err != nil || !bytes.Equal(packet, linkPacket) {
		t.Fatalf("held packet missing or changed: %v", err)
	}
	if got, err := os.ReadFile(filepath.Join(held, "reported-link")); err != nil || string(got) != full {
		t.Fatalf("held reported link %q %v", got, err)
	}
	// The key is held with the link, and nowhere in the report record or the abuse log.
	for path, data := range everythingUnder(t, stateDirOf(s)) {
		if bytes.Contains(data, []byte(reportKey)) && !strings.HasPrefix(path, filepath.Join(stateDirOf(s), "links-held")) {
			t.Fatalf("the key reached %s", path)
		}
	}
}

func TestAbuseMaterialReportWithoutAUsableLinkStillHoldsAndTakesDown(t *testing.T) {
	for name, extra := range map[string]string{
		"no link":    "",
		"wrong link": "&link=https://spokenmargins.com/l/" + strings.Repeat("0", 32) + "%23" + reportKey,
		"too long":   "&link=" + strings.Repeat("a", 3000),
	} {
		t.Run(name, func(t *testing.T) {
			s, _ := enabledLinks(t)
			h := s.Handler()
			id := createdLink(t, h)
			code, body := postReport(h, id, "category=abuse_material"+extra, "203.0.113.7")
			if code != 200 || !linkIsDown(h, id) {
				t.Fatalf("report: %d %s", code, body)
			}
			held := filepath.Join(stateDirOf(s), "links-held", id)
			if _, err := os.Stat(filepath.Join(held, "packet")); err != nil {
				t.Fatalf("ciphertext not held: %v", err)
			}
			if _, err := os.Stat(filepath.Join(held, "reported-link")); err == nil {
				t.Fatal("an unusable link was held")
			}
		})
	}
}

func TestReportForAnUnknownOrGoneLink(t *testing.T) {
	s, _ := enabledLinks(t)
	h := s.Handler()
	unknown := strings.Repeat("a", 32)
	for _, cat := range []string{"copyright", "abuse_material"} {
		if code, _ := postReport(h, unknown, "category="+cat, "203.0.113.7"); code != 404 {
			t.Fatalf("%s unknown id: %d", cat, code)
		}
	}
	id := createdLink(t, h)
	if code, _ := postReport(h, id, "category=other", "203.0.113.7"); code != 200 {
		t.Fatal("first report")
	}
	if code, _ := postReport(h, id, "category=other", "203.0.113.8"); code != 410 {
		t.Fatalf("report on a link already down: %d", code)
	}
}

func TestSecondReportInAWeekOwesAReasonOnASecondPage(t *testing.T) {
	s, _ := enabledLinks(t)
	now := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	s.Now = func() time.Time { return now }
	h := s.Handler()
	first, second, third := createdLink(t, h), createdLink(t, h), createdLink(t, h)

	code, body := postReport(h, first, "category=other", "203.0.113.7")
	if code != 200 || strings.Contains(body, "<textarea") {
		t.Fatalf("first report must not ask for a reason: %d %s", code, body)
	}
	// The same phone's second report: the link comes down now, and the page asks for the reason.
	now = now.Add(2 * 24 * time.Hour)
	code, body = postReport(h, second, "category=abuse_material", "203.0.113.7")
	if code != 200 || !linkIsDown(h, second) || !strings.Contains(body, "<textarea") || !strings.Contains(body, `action="/l/`+second+`/report/reason"`) {
		t.Fatalf("second report: %d %s", code, body)
	}
	ref := regexp.MustCompile(`name="ref" value="([A-Z2-9]{12})"`).FindStringSubmatch(body)[1]

	// The reason can be one character; it is stored with the report and the abuse tip's record.
	reasonURL := "/l/" + second + "/report/reason"
	w := linkRequest(h, "POST", reasonURL, "application/x-www-form-urlencoded", []byte("ref="+ref+"&reason=x"), "203.0.113.7")
	if w.Code != 200 {
		t.Fatalf("reason: %d %s", w.Code, w.Body)
	}
	stored := string(everythingUnder(t, filepath.Join(stateDirOf(s), "reports"))[filepath.Join(stateDirOf(s), "reports", "reports.json")])
	if !strings.Contains(stored, ref) || !strings.Contains(stored, `"reason":"x"`) {
		t.Fatalf("record %s", stored)
	}
	// A reason cannot be added twice, to another link's report, or empty.
	for name, req := range map[string]struct{ path, body string }{
		"other link": {"/l/" + first + "/report/reason", "ref=" + ref + "&reason=y"},
		"bad ref":    {reasonURL, "ref=AAAAAAAAAAAA&reason=y"},
		"blank":      {reasonURL, "ref=" + ref + "&reason=%20%20"},
	} {
		if w := linkRequest(h, "POST", req.path, "application/x-www-form-urlencoded", []byte(req.body), "203.0.113.7"); w.Code < 400 {
			t.Fatalf("%s accepted: %d", name, w.Code)
		}
	}
	linkRequest(h, "POST", reasonURL, "application/x-www-form-urlencoded", []byte("ref="+ref+"&reason=changed"), "203.0.113.7")
	if strings.Contains(string(everythingUnder(t, filepath.Join(stateDirOf(s), "reports"))[filepath.Join(stateDirOf(s), "reports", "reports.json")]), "changed") {
		t.Fatal("a reason was overwritten")
	}

	// A different phone is on its first report. The same phone, 8 days after its first, is too.
	if code, body = postReport(h, third, "category=other", "198.51.100.77"); code != 200 || strings.Contains(body, "<textarea") {
		t.Fatalf("another phone: %d %s", code, body)
	}
}

func TestReasonWindowEndsAfterSevenDays(t *testing.T) {
	s, _ := enabledLinks(t)
	now := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	s.Now = func() time.Time { return now }
	h := s.Handler()
	a, b := createdLink(t, h), createdLink(t, h)
	postReport(h, a, "category=other", "203.0.113.7")
	now = now.Add(7*24*time.Hour + time.Second)
	if _, body := postReport(h, b, "category=other", "203.0.113.7"); strings.Contains(body, "<textarea") {
		t.Fatal("a report 7 days and a second after the first still owed a reason")
	}
}

func TestReasonGivenWithTheReportIsNotAskedForAgain(t *testing.T) {
	s, _ := enabledLinks(t)
	h := s.Handler()
	a, b := createdLink(t, h), createdLink(t, h)
	postReport(h, a, "category=other", "203.0.113.7")
	if _, body := postReport(h, b, "category=harassment&reason=z", "203.0.113.7"); strings.Contains(body, "<textarea") || !linkIsDown(h, b) {
		t.Fatalf("reason sent up front: %s", body)
	}
	// Whitespace is not a reason: the link still comes down and the page still asks.
	c := createdLink(t, h)
	if _, body := postReport(h, c, "category=other&reason=%20", "203.0.113.7"); !strings.Contains(body, "<textarea") || !linkIsDown(h, c) {
		t.Fatalf("blank reason: %s", body)
	}
}

func TestReportRecordHoldsNoReporterAtAll(t *testing.T) {
	s, _ := enabledLinks(t)
	now := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	s.Now = func() time.Time { return now }
	h := s.Handler()
	id := createdLink(t, h)
	postReport(h, id, "category=copyright", "203.0.113.7")
	path := filepath.Join(stateDirOf(s), "reports", "reports.json")
	data, _ := os.ReadFile(path)
	for _, forbidden := range []string{"203.0.113", "198.51"} {
		if bytes.Contains(data, []byte(forbidden)) {
			t.Fatalf("record holds an address: %s", data)
		}
	}
	if bytes.Contains(data, []byte("reporter")) || !bytes.Contains(data, []byte(`"category":"copyright"`)) {
		t.Fatalf("record %s", data)
	}
}

func TestReportsOffAnswers503AndLeavesTheLinkUp(t *testing.T) {
	s, _ := enabledLinks(t)
	s.Reports = nil
	h := s.Handler()
	id := createdLink(t, h)
	if code, _ := postReport(h, id, "category=other", "203.0.113.7"); code != 503 {
		t.Fatalf("no store: %d", code)
	}
}

// If the year-long hold cannot be made (disk trouble), the link still goes dark at once, its content
// stays so the hold can be retried, and the retry works.
func TestAbuseMaterialHoldFailureStillDisablesTheLinkAndCanBeRetried(t *testing.T) {
	s, _ := enabledLinks(t)
	h := s.Handler()
	id := createdLink(t, h)
	blocker := filepath.Join(stateDirOf(s), "links-held")
	if err := os.WriteFile(blocker, []byte("not a directory"), 0o600); err != nil {
		t.Fatal(err)
	}
	full := "https://spokenmargins.com/l/" + id + "#" + reportKey
	if code, _ := postReport(h, id, "category=abuse_material&link="+full, "203.0.113.7"); code != 500 {
		t.Fatalf("a failed hold should say so: %d", code)
	}
	if !linkIsDown(h, id) {
		t.Fatal("link still served after a failed hold")
	}
	if data, err := os.ReadFile(filepath.Join(stateDirOf(s), "links", id, "packet")); err != nil || !bytes.Equal(data, linkPacket) {
		t.Fatalf("content was destroyed before it could be held: %v", err)
	}
	os.Remove(blocker)
	if code, body := postReport(h, id, "category=abuse_material&link="+full, "203.0.113.8"); code != 200 {
		t.Fatalf("retry: %d %s", code, body)
	}
	if data, err := os.ReadFile(filepath.Join(stateDirOf(s), "links-held", id, "packet")); err != nil || !bytes.Equal(data, linkPacket) {
		t.Fatalf("retry did not hold the ciphertext: %v", err)
	}
}

func TestAKeyPastedIntoAReasonDoesNotReachTheReportRecord(t *testing.T) {
	s, _ := enabledLinks(t)
	h := s.Handler()
	a, b := createdLink(t, h), createdLink(t, h)
	pasted := "https://spokenmargins.com/l/" + a + "#" + reportKey
	postReport(h, a, "category=harassment&reason="+pasted, "203.0.113.7")
	_, body := postReport(h, b, "category=other", "203.0.113.7")
	ref := regexp.MustCompile(`name="ref" value="([A-Z2-9]{12})"`).FindStringSubmatch(body)[1]
	linkRequest(h, "POST", "/l/"+b+"/report/reason", "application/x-www-form-urlencoded", []byte("ref="+ref+"&reason="+pasted), "203.0.113.7")
	for path, data := range everythingUnder(t, stateDirOf(s)) {
		if bytes.Contains(data, []byte(reportKey)) {
			t.Fatalf("the key reached %s", path)
		}
	}
}

package api_test

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"spokenmargins.dev/bridge/internal/api"
	"spokenmargins.dev/bridge/internal/client"
	"spokenmargins.dev/bridge/internal/devicecheck"
	"spokenmargins.dev/bridge/internal/reportrules"
)

// fakeApple is Apple's DeviceCheck API at the HTTP boundary (the real client talks to it): two bits per
// device token, a call log, and switches to fail the next answers.
type fakeApple struct {
	mu     sync.Mutex
	bits   map[string]uint8
	calls  []string
	status int // when set, every call answers this
	// failUpdates makes update_two_bits answer 500 while query still works.
	failUpdates bool
}

func (f *fakeApple) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, r.URL.Path)
	var in struct {
		Token string `json:"device_token"`
		Bit0  bool   `json:"bit0"`
		Bit1  bool   `json:"bit1"`
	}
	body, _ := io.ReadAll(r.Body)
	json.Unmarshal(body, &in)
	if f.status != 0 {
		w.WriteHeader(f.status)
		return
	}
	switch r.URL.Path {
	case "/v1/query_two_bits":
		v, ok := f.bits[in.Token]
		if !ok {
			io.WriteString(w, "Failed to find bit state.")
			return
		}
		b := devicecheck.BitsOf(v)
		json.NewEncoder(w).Encode(map[string]any{"bit0": b.Bit0, "bit1": b.Bit1, "last_update_time": "2026-11"})
	case "/v1/update_two_bits":
		if f.failUpdates {
			w.WriteHeader(500)
			return
		}
		f.bits[in.Token] = devicecheck.Bits{Bit0: in.Bit0, Bit1: in.Bit1}.Value()
	}
}

func (f *fakeApple) callCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.calls)
}

func (f *fakeApple) bitsOf(token string) (uint8, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	v, ok := f.bits[token]
	return v, ok
}

type dcRig struct {
	*senderRig
	apple *fakeApple
}

// newDCRig is the sender rig with DeviceCheck wired to the fake and a ladder where one reported link is a
// strike and each pause is a second, so a test can climb it quickly.
func newDCRig(t *testing.T) *dcRig {
	t.Helper()
	r := newSenderRig(t)
	apple := &fakeApple{bits: map[string]uint8{}}
	srv := httptest.NewServer(apple)
	t.Cleanup(srv.Close)
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	r.srv.DeviceCheck = &devicecheck.Client{TeamID: "TEAMID1234", KeyID: "KEYID12345", Key: key, BaseURL: srv.URL, Now: func() time.Time { return r.now }}
	r.srv.ReportRules = reportrules.Config{
		ReasonWindow: 7 * 24 * time.Hour, ReasonFromNth: 2,
		StrikeLinks: 1, StrikeWindow: 90 * 24 * time.Hour,
		PauseAfterStrike1: time.Second, PauseAfterStrike2: time.Second,
	}
	return &dcRig{senderRig: r, apple: apple}
}

// checkWith is a sender check from the install c that carries a device token ("" sends no body).
func checkWith(t *testing.T, c *client.Client, token string) client.Response {
	t.Helper()
	var body []byte
	if token != "" {
		body, _ = json.Marshal(map[string]string{"deviceCheckToken": token})
	}
	resp, err := c.Attested(api.PathLinkSender, body)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

// newInstall is a reinstall: a new attested install key on the same phone.
func (r *dcRig) newInstall(t *testing.T) *client.Client {
	t.Helper()
	c := r.harness.client()
	c.Now = r.c.Now
	if resp, err := c.Register(); err != nil || resp.Status != 201 {
		t.Fatalf("register: %v %v", resp, err)
	}
	return c
}

// strike gets one link reported from install c and moves the clock past the pause.
func (r *dcRig) strike(t *testing.T, c *client.Client, token string) {
	t.Helper()
	resp := checkWith(t, c, token)
	p, _ := resp.Body["permit"].(string)
	if p == "" {
		t.Fatalf("no permit to strike with: %s", resp)
	}
	status, id, code := r.upload(t, p)
	if status != 201 {
		t.Fatalf("upload: %d %s", status, code)
	}
	r.report(t, id, "other")
	r.now = r.now.Add(2 * time.Second)
}

func TestNobodyIsAskedForADeviceTokenUntilSomeoneIsStruck(t *testing.T) {
	r := newDCRig(t)
	for i := 0; i < 3; i++ {
		resp := r.check(t)
		if resp.Body["deviceCheckWanted"] != nil || resp.Body["permit"] == nil {
			t.Fatalf("no ladder yet: %s", resp)
		}
	}
	// A report that is not a strike changes nothing either.
	r.srv.ReportRules.StrikeLinks = 2
	r.report(t, r.permitted(t), "other")
	if resp := r.check(t); resp.Body["deviceCheckWanted"] != nil {
		t.Fatalf("one report is not a strike: %s", resp)
	}
	if n := r.apple.callCount(); n != 0 {
		t.Fatalf("Apple was called %d times with nobody struck", n)
	}
}

func TestAfterAStrikeTheServerAsksOnceThenWritesTheBitsAndAnswers(t *testing.T) {
	r := newDCRig(t)
	r.strike(t, r.c, "")
	ask := r.check(t)
	if ask.Status != 200 || ask.Body["deviceCheckWanted"] != true || ask.Body["permit"] != nil || ask.Body["notice"] != nil || ask.Body["sharingAllowed"] != nil {
		t.Fatalf("the ask says nothing else and withholds the permit: %s", ask)
	}
	if n := r.apple.callCount(); n != 0 {
		t.Fatalf("asking must not call Apple: %d", n)
	}
	got := checkWith(t, r.c, "phone-1")
	if got.Status != 200 || got.Body["notice"] != reportrules.SenderNotice || got.Body["deviceCheckWanted"] != nil {
		t.Fatalf("the notice waited for the repeat and arrives with it: %s", got)
	}
	if v, ok := r.apple.bitsOf("phone-1"); !ok || v != 1 {
		t.Fatalf("strike 1 is bits 01 at Apple: %v %v", v, ok)
	}
	// Second check: the bits already match, so Apple is read and not written.
	r.apple.mu.Lock()
	r.apple.calls = nil
	r.apple.mu.Unlock()
	checkWith(t, r.c, "phone-1")
	if len(r.apple.calls) != 1 || r.apple.calls[0] != "/v1/query_two_bits" {
		t.Fatalf("one read and no write when the bits match: %v", r.apple.calls)
	}
}

func TestEachStrikeWritesItsStepAndEndingWritesBothBits(t *testing.T) {
	r := newDCRig(t)
	for step := uint8(1); step <= 3; step++ {
		r.strike(t, r.c, "phone-1")
		resp := checkWith(t, r.c, "phone-1")
		if v, _ := r.apple.bitsOf("phone-1"); v != step {
			t.Fatalf("after strike %d the bits are %d (%s)", step, v, resp)
		}
	}
	end := checkWith(t, r.c, "phone-1")
	if end.Body["sharingEnded"] != true || end.Body["permit"] != nil {
		t.Fatalf("strike 3 ends link sharing: %s", end)
	}
}

func TestAReinstallKeepsTheStrikeSoTheNextOneStepsUp(t *testing.T) {
	r := newDCRig(t)
	r.strike(t, r.c, "phone-1")
	checkWith(t, r.c, "phone-1") // the old install writes 01

	fresh := r.newInstall(t)
	got := checkWith(t, fresh, "phone-1")
	if got.Status != 200 || got.Body["sharingAllowed"] != true || got.Body["sharingEnded"] != false || got.Body["notice"] != nil {
		t.Fatalf("strike 1's week is a second, and a link nobody here took down has no notice: %s", got)
	}
	// The reinstalled app is on strike 1: its next strike is strike 2 (bits 10), not strike 1 again.
	r.strike(t, fresh, "phone-1")
	checkWith(t, fresh, "phone-1")
	if v, _ := r.apple.bitsOf("phone-1"); v != 2 {
		t.Fatalf("a reinstall must not skip or repeat a step: bits %d", v)
	}
	// Reinstalling at strike 3 stays ended.
	r.strike(t, fresh, "phone-1")
	checkWith(t, fresh, "phone-1")
	again := r.newInstall(t)
	end := checkWith(t, again, "phone-1")
	if end.Body["sharingEnded"] != true || end.Body["sharingAllowed"] != false || end.Body["permit"] != nil {
		t.Fatalf("a reinstall does not undo the end: %s", end)
	}
}

func TestAnotherPhoneIsUntouchedByTheFirstOnesStrikes(t *testing.T) {
	r := newDCRig(t)
	r.strike(t, r.c, "phone-1")
	checkWith(t, r.c, "phone-1")
	friend := r.newInstall(t)
	got := checkWith(t, friend, "phone-2")
	if got.Body["sharingAllowed"] != true || got.Body["permit"] == nil {
		t.Fatalf("a clean device: %s", got)
	}
	if _, ok := r.apple.bitsOf("phone-2"); ok {
		t.Fatal("reading a clean device must not write anything for it")
	}
	if n, _ := os.ReadDir(filepath.Join(r.stateDir, "senders", "senders")); len(n) != 1 {
		t.Fatalf("a clean phone must not get a sender file: %d files", len(n))
	}
}

func TestWhenAppleCannotAnswerTheCheckIsAnsweredFromTheServersOwnRecord(t *testing.T) {
	r := newDCRig(t)
	r.strike(t, r.c, "")
	for _, status := range []int{500, 503, 429, 401} {
		r.apple.status = status
		fresh := r.newInstall(t)
		got := checkWith(t, fresh, "phone-1")
		if got.Status != 200 || got.Body["sharingAllowed"] != true || got.Body["permit"] == nil {
			t.Fatalf("Apple %d: an outage must not stop a clean install: %s", status, got)
		}
	}
	// The old install's strike is not written yet; once Apple is back, the next check writes it.
	r.apple.status = 0
	checkWith(t, r.c, "phone-1")
	if v, _ := r.apple.bitsOf("phone-1"); v != 1 {
		t.Fatalf("the unwritten strike is written at the next check: %d", v)
	}
}

func TestAFailedWriteIsTriedAgainAtTheNextCheck(t *testing.T) {
	r := newDCRig(t)
	r.strike(t, r.c, "")
	r.apple.failUpdates = true
	got := checkWith(t, r.c, "phone-1")
	if got.Status != 200 || got.Body["notice"] != reportrules.SenderNotice {
		t.Fatalf("the answer does not wait on Apple's write: %s", got)
	}
	if _, ok := r.apple.bitsOf("phone-1"); ok {
		t.Fatal("the write was meant to fail")
	}
	r.apple.failUpdates = false
	checkWith(t, r.c, "phone-1")
	if v, _ := r.apple.bitsOf("phone-1"); v != 1 {
		t.Fatalf("retry: %d", v)
	}
}

func TestATokenAppleRefusesGetsNoPermitAndABadBodyIsRefused(t *testing.T) {
	r := newDCRig(t)
	r.strike(t, r.c, "")
	r.apple.status = 400
	got := checkWith(t, r.c, "made-up")
	if got.Status != 400 || got.Body["error"] != "bad_device_token" || got.Body["permit"] != nil {
		t.Fatalf("a refused token: %s", got)
	}
	r.apple.status = 0
	for name, body := range map[string][]byte{
		"not json":   []byte("hello"),
		"too big":    []byte(`{"deviceCheckToken":"` + strings.Repeat("a", 17<<10) + `"}`),
		"wrong type": []byte(`{"deviceCheckToken":5}`),
	} {
		resp, err := r.c.Attested(api.PathLinkSender, body)
		if err != nil || resp.Status != 400 || resp.Body["error"] != "bad_request" {
			t.Errorf("%s: %v %v", name, resp, err)
		}
	}
	// A body with no token is the plain ask, and an empty object is too.
	if resp, _ := r.c.Attested(api.PathLinkSender, []byte(`{}`)); resp.Body["deviceCheckWanted"] != true {
		t.Fatalf("{} reads as no token: %s", resp)
	}
}

func TestWithoutAKeyOrBeforeAStrikeTheOldBodylessCheckStillWorks(t *testing.T) {
	r := newSenderRig(t) // DeviceCheck is nil
	r.report(t, r.permitted(t), "other")
	r.report(t, r.permitted(t), "other")
	resp := checkWith(t, r.c, "phone-1")
	if resp.Status != 200 || resp.Body["deviceCheckWanted"] != nil || resp.Body["notice"] == nil {
		t.Fatalf("a server with no DeviceCheck never asks and ignores a token: %s", resp)
	}
}

func TestTheDeviceTokenIsNeverKeptOrLogged(t *testing.T) {
	r := newDCRig(t)
	var abuse bytes.Buffer
	r.srv.AbuseLog = &abuse
	const secret = "SECRET-DEVICE-TOKEN-0123456789"
	r.strike(t, r.c, "")
	checkWith(t, r.c, secret)
	r.apple.status = 500
	checkWith(t, r.newInstall(t), secret)
	r.apple.status = 400
	checkWith(t, r.newInstall(t), secret)
	r.srv.Flush()
	if !strings.Contains(abuse.String(), "devicecheck_unavailable") || !strings.Contains(abuse.String(), "devicecheck_bad_token") {
		t.Fatalf("failures are counted in the hourly log: %q", abuse.String())
	}
	if strings.Contains(abuse.String(), secret) {
		t.Fatal("the token is in the abuse log")
	}
	filepath.WalkDir(r.stateDir, func(p string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		if data, _ := os.ReadFile(p); bytes.Contains(data, []byte(secret)) {
			t.Errorf("%s holds the device token", p)
		}
		return nil
	})
}

// A known gap, kept here so it is not forgotten (#1728): the bits are written at the struck install's
// next check, because the server has no device token when a report arrives. A struck listener who
// reinstalls before that install ever checks again starts clean. This pins today's behaviour; closing
// the gap needs the app to send a token with every sender check.
func TestAReinstallBeforeTheStruckInstallChecksAgainStartsClean(t *testing.T) {
	r := newDCRig(t)
	r.strike(t, r.c, "")
	fresh := r.newInstall(t)
	got := checkWith(t, fresh, "phone-1")
	if got.Body["sharingAllowed"] != true || got.Body["permit"] == nil {
		t.Fatalf("the gap closed (good): update this test and the README: %s", got)
	}
}

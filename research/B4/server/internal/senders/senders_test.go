package senders_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"spokenmargins.dev/bridge/internal/reportrules"
	"spokenmargins.dev/bridge/internal/senders"
)

var t0 = time.Date(2026, 11, 4, 12, 0, 0, 0, time.UTC)

func linkID(n byte) string { return strings.Repeat(string("0123456789abcdef"[n%16]), 32) }

func open(t *testing.T) (*senders.Store, string) {
	t.Helper()
	dir := t.TempDir()
	s, err := senders.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	return s, dir
}

func bound(t *testing.T, s *senders.Store, handle string, n byte, until time.Time) string {
	t.Helper()
	id := linkID(n)
	if err := s.Bind(id, handle, until); err != nil {
		t.Fatal(err)
	}
	return id
}

func TestTheHandleIsKeyedStableAcrossRestartsAndNeverTheKeyId(t *testing.T) {
	s, dir := open(t)
	keyID := []byte("0123456789abcdef0123456789abcdef")
	h := s.Handle(keyID)
	if len(h) != 64 || h == s.Handle([]byte("another install key id.........!")) {
		t.Fatalf("handle %q", h)
	}
	again, err := senders.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if again.Handle(keyID) != h {
		t.Fatal("a restart must not forget senders: the hash key has to persist")
	}
	other, _ := open(t)
	if other.Handle(keyID) == h {
		t.Fatal("two servers must not share handles: the hash is keyed")
	}
	if info, err := os.Stat(filepath.Join(dir, "key")); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("key file: %v %v", info, err)
	}
}

func TestACorruptKeyFileStopsOpeningInsteadOfMakingANewKey(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "key"), []byte("short"), 0o600)
	if _, err := senders.Open(dir); err == nil {
		t.Fatal("a new key would silently forget every pause")
	}
}

func TestTwoReportedLinksPauseAWeekThenAMonthThenEndSharing(t *testing.T) {
	s, _ := open(t)
	cfg := reportrules.DefaultConfig()
	h := s.Handle([]byte("sender one"))
	now := t0
	report := func(n byte) senders.Outcome {
		t.Helper()
		id := bound(t, s, h, n, now.Add(30*24*time.Hour))
		out, err := s.Report(cfg, id, now)
		if err != nil || !out.Bound {
			t.Fatalf("report: %+v %v", out, err)
		}
		return out
	}

	if out := report(1); out.Struck || out.Step != reportrules.StepClean {
		t.Fatalf("one reported link is not a strike: %+v", out)
	}
	if ok, _ := s.Allowed(h, now); !ok {
		t.Fatal("one reported link must not pause sharing")
	}
	if out := report(2); !out.Struck || out.Step != reportrules.StepStrike1 {
		t.Fatalf("two links: %+v", out)
	}
	st, err := s.Check(h, now)
	if err != nil || st.SharingAllowed || !st.View.SharingPausedUntil.Equal(now.Add(7*24*time.Hour)) || st.View.SharingEnded {
		t.Fatalf("strike 1 standing: %+v %v", st, err)
	}
	if ok, _ := s.Allowed(h, now.Add(7*24*time.Hour-time.Second)); ok {
		t.Fatal("paused for a week")
	}
	now = now.Add(7 * 24 * time.Hour)
	if ok, _ := s.Allowed(h, now); !ok {
		t.Fatal("the week is over")
	}

	report(3)
	if out := report(4); out.Step != reportrules.StepStrike2 {
		t.Fatalf("strike 2: %+v", out)
	}
	if st, _ := s.Check(h, now); !st.View.SharingPausedUntil.Equal(now.Add(30 * 24 * time.Hour)) {
		t.Fatalf("strike 2 pause: %+v", st)
	}
	now = now.Add(30 * 24 * time.Hour)

	report(5)
	if out := report(6); out.Step != reportrules.StepEnded {
		t.Fatalf("strike 3: %+v", out)
	}
	st, _ = s.Check(h, now.Add(10*365*24*time.Hour))
	if st.SharingAllowed || !st.View.SharingEnded || !st.View.SharingPausedUntil.IsZero() {
		t.Fatalf("strike 3 is permanent: %+v", st)
	}
}

func TestTheNoticeIsShownOnceAndSaysNothingButThatALinkCameDown(t *testing.T) {
	s, _ := open(t)
	cfg := reportrules.DefaultConfig()
	h := s.Handle([]byte("sender"))
	if st, _ := s.Check(h, t0); st.View.Notice != "" || !st.SharingAllowed {
		t.Fatalf("a sender nobody reported has no notice: %+v", st)
	}
	if _, err := s.Report(cfg, bound(t, s, h, 1, t0.Add(time.Hour)), t0); err != nil {
		t.Fatal(err)
	}
	st, _ := s.Check(h, t0)
	if st.View.Notice != reportrules.SenderNotice {
		t.Fatalf("notice: %+v", st)
	}
	// Asking does not use the notice up: an answer that never arrives must not lose it.
	if again, _ := s.Check(h, t0); again.View.Notice != reportrules.SenderNotice {
		t.Fatal("Check alone must not clear the notice")
	}
	if err := s.ClearNotice(h); err != nil {
		t.Fatal(err)
	}
	if again, _ := s.Check(h, t0); again.View.Notice != "" {
		t.Fatal("the notice is shown once")
	}
}

func TestTheSameLinkReportedAgainCountsOnce(t *testing.T) {
	s, _ := open(t)
	cfg := reportrules.DefaultConfig()
	h := s.Handle([]byte("sender"))
	id := bound(t, s, h, 1, t0.Add(time.Hour))
	for i := 0; i < 5; i++ {
		if out, err := s.Report(cfg, id, t0.Add(time.Duration(i)*time.Minute)); err != nil || out.Struck {
			t.Fatalf("report %d: %+v %v", i, out, err)
		}
	}
	if ok, _ := s.Allowed(h, t0); !ok {
		t.Fatal("one link is never a strike, however often it is reported")
	}
}

func TestALinkMadeWithoutASenderChangesNothingAndLeavesNoFile(t *testing.T) {
	s, dir := open(t)
	out, err := s.Report(reportrules.DefaultConfig(), linkID(7), t0)
	if err != nil || out.Bound {
		t.Fatalf("%+v %v", out, err)
	}
	entries, _ := os.ReadDir(filepath.Join(dir, "senders"))
	if len(entries) != 0 {
		t.Fatalf("a report of an unattributed link created %d sender files", len(entries))
	}
}

func TestStandingSurvivesARestart(t *testing.T) {
	s, dir := open(t)
	cfg := reportrules.DefaultConfig()
	h := s.Handle([]byte("sender"))
	s.Report(cfg, bound(t, s, h, 1, t0.Add(time.Hour)), t0)
	s.Report(cfg, bound(t, s, h, 2, t0.Add(time.Hour)), t0)
	again, err := senders.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if ok, _ := again.Allowed(h, t0.Add(24*time.Hour)); ok {
		t.Fatal("a restart must not end a pause")
	}
	if st, _ := again.Check(h, t0); st.View.Notice == "" || st.View.SharingPausedUntil.IsZero() {
		t.Fatalf("notice and pause survive a restart: %+v", st)
	}
}

func TestTheSenderFilesHoldNoInstallKeyCategoryOrLinkKey(t *testing.T) {
	s, dir := open(t)
	keyID := []byte("INSTALL-KEY-ID-MUST-NOT-BE-STORED")
	h := s.Handle(keyID)
	cfg := reportrules.DefaultConfig()
	s.Report(cfg, bound(t, s, h, 1, t0.Add(time.Hour)), t0)
	s.Report(cfg, bound(t, s, h, 2, t0.Add(time.Hour)), t0)
	filepath.WalkDir(dir, func(p string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() || filepath.Base(p) == "key" {
			return nil
		}
		data, _ := os.ReadFile(p)
		for _, banned := range []string{string(keyID), linkID(1), linkID(2), "abuse_material", "harassment", "category", "reason"} {
			if strings.Contains(string(data), banned) {
				t.Errorf("%s holds %q", p, banned)
			}
		}
		if info, _ := d.Info(); info.Mode().Perm() != 0o600 {
			t.Errorf("%s mode %v", p, info.Mode())
		}
		return nil
	})
}

func TestSweepDropsExpiredTiesAndCleanSendersAndKeepsAnyoneOnTheLadder(t *testing.T) {
	s, dir := open(t)
	cfg := reportrules.DefaultConfig()
	clean, struck := s.Handle([]byte("clean")), s.Handle([]byte("struck"))
	s.Report(cfg, bound(t, s, clean, 1, t0.Add(30*24*time.Hour)), t0)
	s.ClearNotice(clean) // the notice has been shown
	s.Report(cfg, bound(t, s, struck, 2, t0.Add(30*24*time.Hour)), t0)
	s.Report(cfg, bound(t, s, struck, 3, t0.Add(30*24*time.Hour)), t0)
	bound(t, s, clean, 4, t0.Add(30*24*time.Hour)) // a link nobody reported

	// Day 31: the unreported link has expired, so its tie goes. The clean sender's one reported link
	// is still inside the 90-day window, so their file stays.
	n, err := s.Sweep(cfg, t0.Add(31*24*time.Hour))
	if err != nil || n != 1 {
		t.Fatalf("day 31: deleted %d, %v", n, err)
	}
	if binds, _ := os.ReadDir(filepath.Join(dir, "bindings")); len(binds) != 0 {
		t.Fatalf("%d ties left after their links expired", len(binds))
	}
	files := func() int { e, _ := os.ReadDir(filepath.Join(dir, "senders")); return len(e) }
	if files() != 2 {
		t.Fatalf("day 31: %d sender files", files())
	}
	// Day 91: the clean sender has nothing left that matters. The struck sender stays on the ladder.
	if n, err := s.Sweep(cfg, t0.Add(91*24*time.Hour)); err != nil || n != 1 || files() != 1 {
		t.Fatalf("day 91: deleted %d, %d files left, %v", n, files(), err)
	}
	if ok, _ := s.Allowed(struck, t0.Add(91*24*time.Hour)); !ok {
		t.Fatal("strike 1's week is long over")
	}
	h := s.Handle([]byte("struck"))
	s.Report(cfg, bound(t, s, h, 4, t0.Add(120*24*time.Hour)), t0.Add(92*24*time.Hour))
	if out, _ := s.Report(cfg, bound(t, s, h, 5, t0.Add(120*24*time.Hour)), t0.Add(92*24*time.Hour)); out.Step != reportrules.StepStrike2 {
		t.Fatalf("the step does not decay: %+v", out)
	}
}

func TestIdsThatCouldLeaveTheFolderAreRefused(t *testing.T) {
	s, dir := open(t)
	cfg := reportrules.DefaultConfig()
	h := s.Handle([]byte("sender"))
	for _, bad := range []string{"", "../../key", strings.Repeat("A", 32), strings.Repeat("a", 31), strings.Repeat("a", 33)} {
		if err := s.Bind(bad, h, t0); err == nil {
			t.Errorf("Bind accepted link id %q", bad)
		}
		if _, err := s.Report(cfg, bad, t0); err == nil {
			t.Errorf("Report accepted link id %q", bad)
		}
	}
	for _, bad := range []string{"", "../key", strings.Repeat("g", 64), strings.Repeat("a", 63)} {
		if err := s.Bind(linkID(1), bad, t0); err == nil {
			t.Errorf("Bind accepted handle %q", bad)
		}
		if _, err := s.Check(bad, t0); err == nil {
			t.Errorf("Check accepted handle %q", bad)
		}
		if _, err := s.Allowed(bad, t0); err == nil {
			t.Errorf("Allowed accepted handle %q", bad)
		}
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(dir), "key")); err == nil {
		t.Fatal("something was written outside the folder")
	}
}

func TestAReportEndsTheTieAndTheSenderFileNamesNoLinkId(t *testing.T) {
	s, dir := open(t)
	cfg := reportrules.DefaultConfig()
	h := s.Handle([]byte("sender"))
	id := bound(t, s, h, 9, t0.Add(30*24*time.Hour))
	if out, err := s.Report(cfg, id, t0); err != nil || !out.Bound {
		t.Fatalf("%+v %v", out, err)
	}
	if binds, _ := os.ReadDir(filepath.Join(dir, "bindings")); len(binds) != 0 {
		t.Fatal("the link is down for good, so its tie must go with the report")
	}
	data, err := os.ReadFile(filepath.Join(dir, "senders", h+".json"))
	if err != nil || strings.Contains(string(data), id) {
		t.Fatalf("the sender's file must hold a keyed hash of the link id, not the id: %s %v", data, err)
	}
	// A repeat report of the same link is unattributed now and still counts once.
	if out, _ := s.Report(cfg, id, t0.Add(time.Minute)); out.Bound || out.Struck {
		t.Fatalf("repeat: %+v", out)
	}
}

func TestSweepDeletesTempFilesACrashLeftBehind(t *testing.T) {
	s, dir := open(t)
	old := filepath.Join(dir, "senders", ".tmp-crashed")
	fresh := filepath.Join(dir, "senders", ".tmp-writing")
	os.WriteFile(old, []byte("x"), 0o600)
	os.WriteFile(fresh, []byte("x"), 0o600)
	os.Chtimes(old, t0.Add(-2*time.Hour), t0.Add(-2*time.Hour))
	os.Chtimes(fresh, t0.Add(-time.Minute), t0.Add(-time.Minute))
	if _, err := s.Sweep(reportrules.DefaultConfig(), t0); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(old); err == nil {
		t.Fatal("an old temp file must go")
	}
	if _, err := os.Stat(fresh); err != nil {
		t.Fatal("a write in progress must be left alone")
	}
}

func TestTheLadderIsActiveOnlyOnceSomeoneIsStruckAndStaysSo(t *testing.T) {
	s, dir := open(t)
	cfg := reportrules.DefaultConfig()
	h := s.Handle([]byte("sender"))
	if s.Active() {
		t.Fatal("a server nobody has struck is not on the ladder")
	}
	// One reported link is a report, not a strike.
	s.Report(cfg, bound(t, s, h, 1, t0.Add(30*24*time.Hour)), t0)
	if s.Active() {
		t.Fatal("a report that is not a strike must not turn it on")
	}
	s.Report(cfg, bound(t, s, h, 2, t0.Add(30*24*time.Hour)), t0)
	if !s.Active() {
		t.Fatal("a strike turns it on")
	}
	if st, _ := s.Check(h, t0); st.Step != reportrules.StepStrike1 {
		t.Fatalf("standing carries the step: %+v", st)
	}
	// The marker outlives every sender file, a restart and a sweep.
	if _, err := s.Sweep(cfg, t0.Add(400*24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	reopened, err := senders.Open(dir)
	if err != nil || !reopened.Active() {
		t.Fatalf("after a restart: %v", err)
	}
}

func TestAdoptRaisesTheStepToTheDeviceBitsAndNeverLowersIt(t *testing.T) {
	s, dir := open(t)
	cfg := reportrules.DefaultConfig()
	fresh := s.Handle([]byte("the reinstalled app's new key"))
	if st, err := s.Adopt(fresh, reportrules.StepClean, t0); err != nil || st.Step != reportrules.StepClean || !st.SharingAllowed {
		t.Fatalf("bits 00 change nothing: %+v %v", st, err)
	}
	if s.Active() {
		t.Fatal("adopting a clean step must not turn the ladder on")
	}
	if e, _ := os.ReadDir(filepath.Join(dir, "senders")); len(e) != 0 {
		t.Fatal("adopting a clean step must not make a sender file")
	}

	st, err := s.Adopt(fresh, reportrules.StepStrike2, t0)
	if err != nil || st.Step != reportrules.StepStrike2 || !st.SharingAllowed || !st.View.SharingPausedUntil.IsZero() || st.View.Notice != "" {
		t.Fatalf("strike 2 on the device, no pause and no notice for a link nobody here took down: %+v %v", st, err)
	}
	if !s.Active() {
		t.Fatal("adopting a strike turns the ladder on")
	}
	// The next strike on this install steps up from the device's step, not from clean.
	s.Report(cfg, bound(t, s, fresh, 1, t0.Add(30*24*time.Hour)), t0)
	if out, _ := s.Report(cfg, bound(t, s, fresh, 2, t0.Add(30*24*time.Hour)), t0); out.Step != reportrules.StepEnded {
		t.Fatalf("a reinstall must not skip a step: %+v", out)
	}
	// Lower bits never lower it, and 11 ends sharing for good.
	if st, _ := s.Adopt(fresh, reportrules.StepClean, t0); st.Step != reportrules.StepEnded || st.SharingAllowed {
		t.Fatalf("a step does not go down: %+v", st)
	}
	other := s.Handle([]byte("another"))
	if st, _ := s.Adopt(other, reportrules.StepEnded, t0); st.Step != reportrules.StepEnded || st.SharingAllowed || !st.View.SharingEnded {
		t.Fatalf("bits 11: %+v", st)
	}
	if _, err := s.Adopt("../key", reportrules.StepStrike1, t0); err == nil {
		t.Fatal("a bad handle was accepted")
	}
}

func TestOpeningAnOlderFolderWithAStruckSenderTurnsTheLadderOn(t *testing.T) {
	s, dir := open(t)
	cfg := reportrules.DefaultConfig()
	h := s.Handle([]byte("sender"))
	s.Report(cfg, bound(t, s, h, 1, t0.Add(30*24*time.Hour)), t0)
	s.Report(cfg, bound(t, s, h, 2, t0.Add(30*24*time.Hour)), t0)
	// A server from before the marker existed: same files, no marker.
	if err := os.Remove(filepath.Join(dir, "ladder")); err != nil {
		t.Fatal(err)
	}
	reopened, err := senders.Open(dir)
	if err != nil || !reopened.Active() {
		t.Fatalf("a struck sender on file must turn it on: %v", err)
	}
	// A folder whose only sender file is clean stays off.
	clean, cdir := open(t)
	clean.Report(cfg, bound(t, clean, clean.Handle([]byte("c")), 1, t0.Add(30*24*time.Hour)), t0)
	if again, err := senders.Open(cdir); err != nil || again.Active() {
		t.Fatalf("one report is not a strike: %v", err)
	}
}

package reportrules

import (
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"
)

var t0 = time.Date(2026, 11, 1, 12, 0, 0, 0, time.UTC)

const day = 24 * time.Hour

func TestEveryCategoryIsParsedAndNothingElseIs(t *testing.T) {
	for _, c := range Categories() {
		got, err := ParseCategory(string(c))
		if err != nil || got != c {
			t.Errorf("ParseCategory(%q) = %q, %v", c, got, err)
		}
	}
	if len(Categories()) != 6 {
		t.Errorf("the form has six categories, got %d", len(Categories()))
	}
	if _, err := ParseCategory(""); !errors.Is(err, ErrCategoryRequired) {
		t.Errorf("empty: %v, want ErrCategoryRequired", err)
	}
	// Neighbouring inputs: case, whitespace, lookalikes, long values.
	for _, s := range []string{"Copyright", "COPYRIGHT", " copyright", "copyright ", "copyright\n", "copy right",
		"abuse-material", "csam", "intimate", "0", "other,copyright", "other\x00", string(make([]byte, 5000))} {
		if got, err := ParseCategory(s); !errors.Is(err, ErrCategoryUnknown) || got != "" {
			t.Errorf("ParseCategory(%q) = %q, %v; want ErrCategoryUnknown", s, got, err)
		}
	}
}

func TestFormCannotFileWithoutACategory(t *testing.T) {
	cfg := DefaultConfig()
	for _, cat := range []string{"", "nonsense"} {
		d := cfg.Intake(Submission{Category: cat, Reason: "because"}, nil, t0)
		if d.Err == nil || d.DisableLink || d.CountsForSender {
			t.Errorf("category %q: %+v, want an error and nothing filed", cat, d)
		}
	}
}

func TestEveryCategoryDisablesTheLinkAtOnceAndCountsForTheSender(t *testing.T) {
	cfg := DefaultConfig()
	for _, c := range Categories() {
		d := cfg.Intake(Submission{Category: string(c)}, nil, t0)
		if d.Err != nil || !d.DisableLink || !d.CountsForSender {
			t.Errorf("%s: %+v, want filed, link disabled, counted", c, d)
		}
		if d.SendFullLink != (c == AbuseMaterial) {
			t.Errorf("%s: SendFullLink = %v; only abuse_material carries the key", c, d.SendFullLink)
		}
	}
}

func TestFirstReportNeedsNoReason(t *testing.T) {
	d := DefaultConfig().Intake(Submission{Category: string(Other)}, nil, t0)
	if d.ReasonRequired || d.ReasonOutstanding {
		t.Errorf("first report: %+v, want no reason owed", d)
	}
}

func TestSecondReportWithinSevenDaysOwesAReasonInEveryCategory(t *testing.T) {
	cfg := DefaultConfig()
	prior := []time.Time{t0.Add(-2 * day)}
	for _, c := range Categories() {
		d := cfg.Intake(Submission{Category: string(c)}, prior, t0)
		if !d.ReasonRequired || !d.ReasonOutstanding {
			t.Errorf("%s: %+v, want a reason required and outstanding (abuse_material and intimate_images included)", c, d)
		}
		// The takedown does not wait for the reason.
		if !d.DisableLink {
			t.Errorf("%s: link must be disabled even while the reason is outstanding", c)
		}
	}
}

func TestAnyLengthOfReasonIsEnough(t *testing.T) {
	cfg := DefaultConfig()
	prior := []time.Time{t0.Add(-time.Hour)}
	for _, reason := range []string{"x", "?", "é", "🙂", " ok ", "a longer written reason\nover two lines"} {
		d := cfg.Intake(Submission{Category: string(AbuseMaterial), Reason: reason}, prior, t0)
		if !d.ReasonRequired || d.ReasonOutstanding {
			t.Errorf("reason %q: %+v, want required and satisfied", reason, d)
		}
	}
	for _, reason := range []string{"", " ", "\t\n", " ", "  "} {
		if HasReason(reason) {
			t.Errorf("HasReason(%q) = true; whitespace says nothing", reason)
		}
		d := cfg.Intake(Submission{Category: string(Harassment), Reason: reason}, prior, t0)
		if !d.ReasonOutstanding {
			t.Errorf("reason %q: want outstanding", reason)
		}
	}
}

func TestReasonWindowEdges(t *testing.T) {
	cfg := DefaultConfig()
	cases := []struct {
		name  string
		prior []time.Time
		want  bool
	}{
		{"none", nil, false},
		{"one hour ago", []time.Time{t0.Add(-time.Hour)}, true},
		{"exactly seven days ago", []time.Time{t0.Add(-7 * day)}, true},
		{"seven days and a nanosecond ago", []time.Time{t0.Add(-7*day - 1)}, false},
		{"a month ago", []time.Time{t0.Add(-30 * day)}, false},
		{"old one and a recent one", []time.Time{t0.Add(-30 * day), t0.Add(-day)}, true},
		{"dated slightly ahead (clock skew)", []time.Time{t0.Add(time.Second)}, true},
	}
	for _, c := range cases {
		d := cfg.Intake(Submission{Category: string(Other)}, c.prior, t0)
		if d.ReasonRequired != c.want {
			t.Errorf("%s: ReasonRequired = %v, want %v", c.name, d.ReasonRequired, c.want)
		}
	}
}

func TestReasonSettingsAreHonoured(t *testing.T) {
	cfg := DefaultConfig()
	cfg.ReasonWindow = day
	cfg.ReasonFromNth = 3
	prior := []time.Time{t0.Add(-time.Hour)}
	if cfg.Intake(Submission{Category: string(Other)}, prior, t0).ReasonRequired {
		t.Error("third-report setting: second report must not owe a reason")
	}
	prior = append(prior, t0.Add(-2*time.Hour))
	if !cfg.Intake(Submission{Category: string(Other)}, prior, t0).ReasonRequired {
		t.Error("third-report setting: third report owes a reason")
	}
	prior = []time.Time{t0.Add(-2 * day), t0.Add(-3 * day)}
	if cfg.Intake(Submission{Category: string(Other)}, prior, t0).ReasonRequired {
		t.Error("reports outside the 1-day setting must not count")
	}
}

func TestEmailedReportsAreNeverBlockedByDevice(t *testing.T) {
	if StepEnded.ReportingAllowed(ChannelForm) {
		t.Error("bits 11 must block reporting from the app")
	}
	if !StepEnded.ReportingAllowed(ChannelEmail) {
		t.Error("an emailed report must keep working")
	}
	for _, s := range []Step{StepClean, StepStrike1, StepStrike2} {
		if !s.ReportingAllowed(ChannelForm) {
			t.Errorf("step %d must still allow reporting", s)
		}
	}
	// An emailed report over the limit still files and still takes the link down;
	// it just has the reason asked for by reply.
	d := DefaultConfig().Intake(Submission{Category: string(Other), Channel: ChannelEmail},
		[]time.Time{t0.Add(-time.Hour)}, t0)
	if !d.DisableLink || !d.ReasonOutstanding {
		t.Errorf("emailed second report: %+v", d)
	}
}

func TestDeviceCheckBits(t *testing.T) {
	want := map[Step]uint8{StepClean: 0b00, StepStrike1: 0b01, StepStrike2: 0b10, StepEnded: 0b11}
	for s, b := range want {
		if s.Bits() != b {
			t.Errorf("step %d bits = %02b, want %02b", s, s.Bits(), b)
		}
		back, ok := StepFromBits(b)
		if !ok || back != s {
			t.Errorf("StepFromBits(%02b) = %d, %v", b, back, ok)
		}
	}
	if _, ok := StepFromBits(4); ok {
		t.Error("StepFromBits(4) must be refused")
	}
}

func report(t *testing.T, cfg Config, st SenderState, id string, at time.Time) (SenderState, StrikeResult) {
	t.Helper()
	return cfg.RecordReportedLink(st, id, at)
}

func TestOneReportedLinkIsNotAStrike(t *testing.T) {
	st, res := report(t, DefaultConfig(), SenderState{}, "a", t0)
	if !res.Counted || res.Struck || st.Step != StepClean || !st.SharingAllowed(t0) {
		t.Errorf("%+v %+v", st, res)
	}
}

func TestTwoReportedLinksInNinetyDaysAreAStrikeWithAWeekPause(t *testing.T) {
	cfg := DefaultConfig()
	st, _ := report(t, cfg, SenderState{}, "a", t0)
	at := t0.Add(89 * day)
	st, res := report(t, cfg, st, "b", at)
	if !res.Struck || st.Step != StepStrike1 {
		t.Fatalf("%+v %+v", st, res)
	}
	if want := at.Add(7 * day); !st.PausedUntil.Equal(want) {
		t.Errorf("PausedUntil = %v, want %v", st.PausedUntil, want)
	}
	if unusedLinks(st) != 0 {
		t.Errorf("the two links are used up by the strike: %+v", st.Links)
	}
	if st.SharingAllowed(at) || st.SharingAllowed(at.Add(7*day-time.Nanosecond)) {
		t.Error("sharing must be paused for the whole week")
	}
	if !st.SharingAllowed(at.Add(7 * day)) {
		t.Error("sharing resumes when the week is over")
	}
}

func TestLinksFarApartAreNotAStrike(t *testing.T) {
	cfg := DefaultConfig()
	st, _ := report(t, cfg, SenderState{}, "a", t0)
	// Exactly 90 days still counts; a nanosecond later it does not.
	if _, res := report(t, cfg, st, "b", t0.Add(90*day)); !res.Struck {
		t.Error("90 days to the instant is still within 90 days")
	}
	st2, res := report(t, cfg, st, "b", t0.Add(90*day+1))
	if res.Struck || st2.Step != StepClean {
		t.Errorf("past 90 days: %+v %+v", st2, res)
	}
	if len(st2.Links) != 1 || st2.Links[0].ID != "b" {
		t.Errorf("the aged-out link must drop out: %+v", st2.Links)
	}
}

func TestTheSameLinkReportedAgainCountsOnce(t *testing.T) {
	cfg := DefaultConfig()
	st, _ := report(t, cfg, SenderState{}, "a", t0)
	for i := 0; i < 5; i++ {
		var res StrikeResult
		st, res = report(t, cfg, st, "a", t0.Add(time.Duration(i+1)*time.Hour))
		if res.Counted || res.Struck || st.Step != StepClean {
			t.Fatalf("repeat %d: %+v %+v", i, st, res)
		}
	}
	if len(st.Links) != 1 {
		t.Errorf("links = %+v, want one link", st.Links)
	}
}

func TestLadderIsWeekThenMonthThenPermanent(t *testing.T) {
	cfg := DefaultConfig()
	var st SenderState
	now := t0
	step := func(a, b string) StrikeResult {
		t.Helper()
		st, _ = report(t, cfg, st, a, now)
		var res StrikeResult
		st, res = report(t, cfg, st, b, now.Add(time.Hour))
		now = now.Add(time.Hour)
		return res
	}

	if res := step("1a", "1b"); !res.Struck || st.Step != StepStrike1 || !st.PausedUntil.Equal(now.Add(7*day)) {
		t.Fatalf("strike 1: %+v %+v", st, res)
	}
	now = now.Add(8 * day) // pause over
	if !st.SharingAllowed(now) {
		t.Fatal("sharing is back after the week")
	}
	if res := step("2a", "2b"); !res.Struck || st.Step != StepStrike2 || !st.PausedUntil.Equal(now.Add(30*day)) {
		t.Fatalf("strike 2: %+v %+v", st, res)
	}
	now = now.Add(31 * day)
	if !st.SharingAllowed(now) {
		t.Fatal("sharing is back after the month")
	}
	if res := step("3a", "3b"); !res.Struck || st.Step != StepEnded || !st.PausedUntil.IsZero() {
		t.Fatalf("strike 3: %+v %+v", st, res)
	}
	for _, later := range []time.Duration{0, day, 365 * day, 100 * 365 * day} {
		if st.SharingAllowed(now.Add(later)) {
			t.Errorf("sharing must stay ended %v later", later)
		}
	}
	// An ended sender does not climb further or collect pending links.
	after, res := report(t, cfg, st, "4a", now)
	if res.Counted || res.Struck || after.Step != StepEnded || len(after.Links) != 0 {
		t.Errorf("after the end: %+v %+v", after, res)
	}
}

func unusedLinks(st SenderState) int {
	n := 0
	for _, l := range st.Links {
		if !l.Used {
			n++
		}
	}
	return n
}

// The ladder takes link ids and times only, never a category, so no category can
// change it. What can differ by category is whether Intake says the report counts.
func TestEveryCategoryCountsTowardTheSenderLadder(t *testing.T) {
	cfg := DefaultConfig()
	for _, c := range Categories() {
		if d := cfg.Intake(Submission{Category: string(c)}, nil, t0); !d.CountsForSender {
			t.Errorf("%s must count toward the sender", c)
		}
	}
}

// A link that took part in a strike must not count a second time when it is
// reported again after the strike (found in review).
func TestALinkUsedByAStrikeIsNotCountedAgain(t *testing.T) {
	cfg := DefaultConfig()
	st, _ := report(t, cfg, SenderState{}, "a", t0)
	st, _ = report(t, cfg, st, "b", t0.Add(time.Hour)) // strike 1
	st, res := report(t, cfg, st, "a", t0.Add(2*time.Hour))
	if res.Counted || res.Struck {
		t.Fatalf("re-report of a used link: %+v", res)
	}
	st, res = report(t, cfg, st, "c", t0.Add(3*time.Hour))
	if !res.Counted || res.Struck || st.Step != StepStrike1 {
		t.Fatalf("one new link after a strike is not a strike: %+v %+v", st, res)
	}
	if st, res = report(t, cfg, st, "d", t0.Add(4*time.Hour)); !res.Struck || st.Step != StepStrike2 {
		t.Fatalf("two new links are: %+v %+v", st, res)
	}
}

func TestReportsDuringAPauseBuildTheNextStrike(t *testing.T) {
	cfg := DefaultConfig()
	st, _ := report(t, cfg, SenderState{}, "a", t0)
	st, _ = report(t, cfg, st, "b", t0.Add(time.Hour)) // strike 1, paused a week
	st, _ = report(t, cfg, st, "c", t0.Add(2*time.Hour))
	st, res := report(t, cfg, st, "d", t0.Add(3*time.Hour)) // links made before the pause are still live
	if !res.Struck || st.Step != StepStrike2 {
		t.Fatalf("%+v %+v", st, res)
	}
	if want := t0.Add(3*time.Hour + 30*day); !st.PausedUntil.Equal(want) {
		t.Errorf("PausedUntil = %v, want %v", st.PausedUntil, want)
	}
}

func TestRecordReportedLinkDoesNotModifyItsInput(t *testing.T) {
	cfg := DefaultConfig()
	in := SenderState{Links: []ReportedLink{{ID: "a", At: t0}}}
	snapshot := SenderState{Links: append([]ReportedLink(nil), in.Links...)}
	out, _ := cfg.RecordReportedLink(in, "b", t0.Add(time.Hour))
	if !reflect.DeepEqual(in, snapshot) {
		t.Errorf("input changed: %+v", in)
	}
	out.Links = append(out.Links, ReportedLink{ID: "z"})
	if !reflect.DeepEqual(in, snapshot) {
		t.Error("output shares storage with the input")
	}
}

// ViewFor takes the sender's state, which holds no category, so the notice
// cannot depend on one. This pins the exact text and that it names no category.
func TestSenderNoticeIsGenericAndNamesNoCategory(t *testing.T) {
	if SenderNotice != "A link you shared was taken down after a report" {
		t.Errorf("notice text changed: %q", SenderNotice)
	}
	for _, c := range Categories() {
		if strings.Contains(strings.ToLower(SenderNotice), strings.ToLower(string(c))) {
			t.Errorf("the notice must not name %q", c)
		}
	}
	st := SenderState{Links: []ReportedLink{{ID: "a", At: t0}}}
	if v := ViewFor(st, true, t0); v.Notice != SenderNotice {
		t.Errorf("view notice = %q", v.Notice)
	}
	if v := ViewFor(st, false, t0); v.Notice != "" {
		t.Errorf("no takedown, no notice: %q", v.Notice)
	}
}

func TestSenderViewCarriesThePauseOnlyWhileItRuns(t *testing.T) {
	cfg := DefaultConfig()
	st, _ := report(t, cfg, SenderState{}, "a", t0)
	st, _ = report(t, cfg, st, "b", t0)
	v := ViewFor(st, false, t0.Add(day))
	if v.Notice != "" || v.SharingEnded || !v.SharingPausedUntil.Equal(t0.Add(7*day)) {
		t.Errorf("during the pause: %+v", v)
	}
	v = ViewFor(st, false, t0.Add(8*day))
	if !v.SharingPausedUntil.IsZero() {
		t.Errorf("after the pause: %+v", v)
	}
	ended := SenderState{Step: StepEnded}
	if v := ViewFor(ended, true, t0); !v.SharingEnded || !v.SharingPausedUntil.IsZero() || v.Notice != SenderNotice {
		t.Errorf("ended: %+v", v)
	}
}

// Package reportrules holds the pure rules behind "Report this link" (#2239,
// owner decision 2026-10-20, D18 and D21 in docs/legal/attorney-questions.md):
// which categories exist, when a reporter owes a written reason, what the sender
// is told, and the strike ladder that pauses and then ends a sender's link sharing.
//
// It does no I/O and imports nothing from the server. A caller supplies the
// stored history (keyed hashes only, never the content) and the clock, and gets
// back a decision. No handler, route or store uses it yet; the report form, the
// takedown and the hold for the CyberTipline (#3115, #2235) are separate slices,
// and share-link creation stays behind its build-time gate (docs/legal/gate-record.json,
// scripts/release_gate.py). The rules still need counsel's answers to questions 4
// and 5 in docs/legal/attorney-questions.md (a ladder ending in permanent
// termination under 17 U.S.C. § 512(i); a notice that never names the category
// under the EU DSA Art. 17); the numbers here are the owner's starting numbers.
//
// What this package never does, on purpose:
//   - read or take a report's content, or decide anything from it;
//   - keep the category on the sender's side: the sender's state holds link ids
//     and times only, so no notice can depend on the category;
//   - block a reporter. A reporter is blocked only by the owner's manual call
//     after reading their written reasons, so there is no automatic path here.
package reportrules

import (
	"errors"
	"strings"
	"time"
)

// Category is what a reporter picks on the form. It is required from the first report.
type Category string

const (
	// IntimateImages is intimate images shared without consent (Take It Down Act).
	IntimateImages Category = "intimate_images"
	// AbuseMaterial is child sexual abuse material. It is the only category whose
	// report carries the full link, key included (D21), so it can be forwarded
	// unread to the CyberTipline.
	AbuseMaterial Category = "abuse_material"
	Harassment    Category = "harassment"
	Hateful       Category = "hateful_conduct"
	// Copyright points the reporter to the designated agent (#2236) but still
	// takes the link down at once, like every other category.
	Copyright Category = "copyright"
	Other     Category = "other"
)

// Categories lists every category in form order.
func Categories() []Category {
	return []Category{IntimateImages, AbuseMaterial, Harassment, Hateful, Copyright, Other}
}

var (
	// ErrCategoryRequired: the form was submitted without a category. Nothing is filed.
	ErrCategoryRequired = errors.New("reportrules: a category is required")
	// ErrCategoryUnknown: the category is not one of Categories. Nothing is filed.
	ErrCategoryUnknown = errors.New("reportrules: unknown category")
)

// ParseCategory checks a submitted category value exactly; it does not guess
// at near matches, so a tampered form value is refused rather than filed as Other.
func ParseCategory(s string) (Category, error) {
	if s == "" {
		return "", ErrCategoryRequired
	}
	for _, c := range Categories() {
		if string(c) == s {
			return c, nil
		}
	}
	return "", ErrCategoryUnknown
}

// CarriesKey reports whether a report in this category sends the full link,
// key included. Every other category sends the link id only.
func (c Category) CarriesKey() bool { return c == AbuseMaterial }

// Config holds the numbers. DefaultConfig is the owner's 2026-10-20 rule; a
// deployment may change them (the 7-day window is "a setting" in #2239).
type Config struct {
	// ReasonWindow and ReasonFromNth: a reporter's Nth report within ReasonWindow
	// (counting the earlier ones in the window) must give a written reason.
	ReasonWindow  time.Duration
	ReasonFromNth int

	// A strike is StrikeLinks distinct reported links within StrikeWindow.
	StrikeLinks  int
	StrikeWindow time.Duration

	// PauseAfterStrike1 and PauseAfterStrike2 are how long link sharing is paused.
	// Strike 3 is permanent.
	PauseAfterStrike1 time.Duration
	PauseAfterStrike2 time.Duration
}

// DefaultConfig is the owner's rule of 2026-10-20: a second report within 7 days
// needs a written reason; two reported links within 90 days are a strike; the
// pauses are 1 week and 1 month, then permanent. "A month" is 30 days, so the
// token's expiry never depends on the calendar.
func DefaultConfig() Config {
	const day = 24 * time.Hour
	return Config{
		ReasonWindow:      7 * day,
		ReasonFromNth:     2,
		StrikeLinks:       2,
		StrikeWindow:      90 * day,
		PauseAfterStrike1: 7 * day,
		PauseAfterStrike2: 30 * day,
	}
}

// within reports whether an event at `then` still counts at `now`. The edge is
// inclusive: a report exactly one window old still counts, one nanosecond older
// does not. An event dated after now (clock skew) counts.
func within(then, now time.Time, window time.Duration) bool {
	return now.Sub(then) <= window
}

// Channel is how the report arrived.
type Channel int

const (
	// ChannelForm is the web form or the app.
	ChannelForm Channel = iota
	// ChannelEmail is a report emailed to the designated address. An email-only
	// reporter has no device to block, and their reports keep working (default 4).
	ChannelEmail
)

// Submission is what the reporter sent. Reason is the optional written reason.
type Submission struct {
	Category string
	Reason   string
	Channel  Channel
}

// Decision is the outcome of one submission.
type Decision struct {
	// Err is non-nil only for a category problem. Then nothing is filed and the
	// link stays up. Every other submission is filed.
	Err      error
	Category Category

	// DisableLink is true for every filed report, in every category, whether or
	// not a reason is still owed. The takedown never waits for the reason (#2239).
	DisableLink bool

	// ReasonRequired: this is the reporter's report that owes a written reason.
	// ReasonOutstanding: it is required and was not supplied, so the form shows its
	// second page (or, for an emailed report, the reply asks for it). The link is
	// already disabled either way.
	ReasonRequired    bool
	ReasonOutstanding bool

	// SendFullLink: the form must send the key too (abuse-material only).
	SendFullLink bool

	// CountsForSender: the reported link counts toward the sender's strike ladder.
	// It is true for every filed report; the category never changes it.
	CountsForSender bool
}

// Intake decides one submission. priorReports are the times of this reporter's
// earlier reports (same phone or same reply email), as kept for the 7-day window;
// the caller never passes their content.
func (c Config) Intake(sub Submission, priorReports []time.Time, now time.Time) Decision {
	cat, err := ParseCategory(sub.Category)
	if err != nil {
		return Decision{Err: err}
	}
	inWindow := 0
	for _, t := range priorReports {
		if within(t, now, c.ReasonWindow) {
			inWindow++
		}
	}
	required := inWindow+1 >= c.ReasonFromNth
	return Decision{
		Category:          cat,
		DisableLink:       true,
		ReasonRequired:    required,
		ReasonOutstanding: required && !HasReason(sub.Reason),
		SendFullLink:      cat.CarriesKey(),
		CountsForSender:   true,
	}
}

// HasReason reports whether a written reason is given. Any length counts, even
// one character; text that is only whitespace does not, because it says nothing.
func HasReason(reason string) bool {
	return strings.TrimSpace(reason) != ""
}

// Step is the sender's place on the ladder. The numeric value is the two
// DeviceCheck bits: 00 clean, 01 after strike 1, 10 after strike 2, 11 ended.
type Step uint8

const (
	StepClean   Step = 0
	StepStrike1 Step = 1
	StepStrike2 Step = 2
	// StepEnded is strike 3: link sharing is over for good. The same bits also
	// block reporting from the app on that device (default taken in #2239).
	StepEnded Step = 3
)

// Bits returns the two DeviceCheck bits for the step.
func (s Step) Bits() uint8 { return uint8(s) & 0b11 }

// StepFromBits is the inverse of Bits. It refuses values above 3.
func StepFromBits(b uint8) (Step, bool) {
	if b > 3 {
		return 0, false
	}
	return Step(b), true
}

// ReportingAllowed: bits 11 block reporting from the app on that device. An
// emailed report is never blocked this way.
func (s Step) ReportingAllowed(ch Channel) bool {
	return ch == ChannelEmail || s != StepEnded
}

// ReportedLink is a link id and the time its first report was filed. The
// sender's state keeps nothing else about a report.
type ReportedLink struct {
	ID string
	At time.Time
}

// SenderState is everything the ladder needs about one sender (kept under a
// keyed hash of the install key, never the key itself). It holds no category.
type SenderState struct {
	Step Step
	// Pending are reported links not yet used up by a strike.
	Pending []ReportedLink
	// PausedUntil is zero unless a week or month pause is running.
	PausedUntil time.Time
}

// SharingAllowed: may this sender create a link at `now`? Direct .spokenmargins
// file sharing is never affected and is not asked of this function.
func (st SenderState) SharingAllowed(now time.Time) bool {
	if st.Step == StepEnded {
		return false
	}
	return st.PausedUntil.IsZero() || !now.Before(st.PausedUntil)
}

// StrikeResult tells the caller what a recorded report did to the sender.
type StrikeResult struct {
	// Counted is false when the link was already counted (the same link reported
	// again, by anyone) or the sender had already ended.
	Counted bool
	// Struck is true when this report completed a strike.
	Struck bool
}

// RecordReportedLink adds one report to the sender's state at `at` and returns
// the new state. A link counts once however often or by whomever it is reported.
// When StrikeLinks distinct links sit inside StrikeWindow, that is a strike: the
// step rises, the pending links are used up, and a pause starts (permanent at the
// third). Reports for a sender's links keep counting during a pause, because
// links made earlier stay live until they expire; they build the next strike.
//
// The input state is not modified.
func (c Config) RecordReportedLink(st SenderState, linkID string, at time.Time) (SenderState, StrikeResult) {
	out := SenderState{Step: st.Step, PausedUntil: st.PausedUntil}
	if st.Step == StepEnded {
		return out, StrikeResult{}
	}
	for _, p := range st.Pending {
		if p.ID == linkID {
			out.Pending = append([]ReportedLink(nil), st.Pending...)
			return out, StrikeResult{}
		}
		if within(p.At, at, c.StrikeWindow) {
			out.Pending = append(out.Pending, p)
		}
	}
	out.Pending = append(out.Pending, ReportedLink{ID: linkID, At: at})
	if len(out.Pending) < c.StrikeLinks {
		return out, StrikeResult{Counted: true}
	}
	out.Pending = nil
	switch st.Step {
	case StepClean:
		out.Step, out.PausedUntil = StepStrike1, at.Add(c.PauseAfterStrike1)
	case StepStrike1:
		out.Step, out.PausedUntil = StepStrike2, at.Add(c.PauseAfterStrike2)
	default:
		out.Step, out.PausedUntil = StepEnded, time.Time{}
	}
	return out, StrikeResult{Counted: true, Struck: true}
}

// SenderNotice is the only thing a sender is told about a report. It is the same
// for every category and never names one, so an abuse-material takedown looks
// like any other. There is no dispute button, no contact and no "this was a
// mistake" action.
const SenderNotice = "A link you shared was taken down after a report"

// SenderView is what the sender's app learns on its next check. It is built from
// SenderState alone, which holds no category, so it cannot vary by category.
type SenderView struct {
	// Notice is SenderNotice when a link was taken down, else empty.
	Notice string
	// SharingPausedUntil is the server-signed token's expiry for a week or month
	// pause; zero otherwise.
	SharingPausedUntil time.Time
	// SharingEnded is true after strike 3.
	SharingEnded bool
}

// ViewFor builds the sender's view. linkTakenDown is whether any of the sender's
// links was taken down since the app's last check.
func ViewFor(st SenderState, linkTakenDown bool, now time.Time) SenderView {
	v := SenderView{SharingEnded: st.Step == StepEnded}
	if linkTakenDown {
		v.Notice = SenderNotice
	}
	if !v.SharingEnded && now.Before(st.PausedUntil) {
		v.SharingPausedUntil = st.PausedUntil
	}
	return v
}

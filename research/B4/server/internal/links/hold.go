package links

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// A link reported to the CyberTipline is held for one year instead of expiring in 30 days (#2235,
// 18 U.S.C. 2258A(h)). The held copy lives in a sibling directory of the links directory, mode 0700, so
// the serving paths in this package, which only look inside the links directory, can never reach it.
// Nobody opens held content: the package has no read call for it, only Hold, SweepHeld and ReleaseHeld.
//
// What is held is what the server already has: the sealed packet and sealed preview, as stored, and the
// full link (key included) that an abuse-material report sent, as received. The full link is never parsed
// or logged here.
const (
	heldSuffix  = "-held"
	holdMeta    = "hold.json"
	reportedRef = "reported-link"
	accessLog   = "access.log"
)

var (
	// ErrBadReportID is returned when the CyberTipline report id is empty or has a character that could
	// break the one-line access log.
	ErrBadReportID = errors.New("links: bad report id")
	ErrNotHeld     = errors.New("links: not held")
	ErrNoReason    = errors.New("links: a release needs a stated reason")
	// ErrHoldCap is returned when a new hold would pass a cap. The link is not held and not taken down:
	// the caller parks it (Disable) so its content stays for the owner to hold by hand.
	ErrHoldCap = errors.New("links: hold cap reached")
)

// MaxReportedLinks is how many distinct reported links one held item keeps. A report form can be posted
// by anyone who knows a link id, so the first link seen must not be the only one kept: a junk link posted
// ahead of the real reporter would otherwise lock the real key out. A sixth distinct link is not kept
// and the access log says so.
const MaxReportedLinks = 5

// ownerMaxReportedLinks bounds the owner's own `hold` runs, which are not limited to MaxReportedLinks.
const ownerMaxReportedLinks = 64

// HoldLimits caps what the public report path can make this server keep for a year. A zero field means
// its default. The caps exist because one upload (30 an hour per client, up to 20 MB) can be reported
// as abuse material by anyone, and every held copy outlives the 30-day expiry by eleven months. The owner's
// own `hold` command (HoldByOwner) is not limited by them.
type HoldLimits struct {
	MaxItems       int   // held items in total
	MaxBytes       int64 // packet and preview bytes held in total
	MaxItemsPerDay int   // new holds begun in one UTC day
}

// DefaultHoldLimits is a Default taken on #3120 (the owner can change it): 500 items, 5 GiB, 50 a day.
var DefaultHoldLimits = HoldLimits{MaxItems: 500, MaxBytes: 5 << 30, MaxItemsPerDay: 50}

func (l HoldLimits) withDefaults() HoldLimits {
	if l.MaxItems <= 0 {
		l.MaxItems = DefaultHoldLimits.MaxItems
	}
	if l.MaxBytes <= 0 {
		l.MaxBytes = DefaultHoldLimits.MaxBytes
	}
	if l.MaxItemsPerDay <= 0 {
		l.MaxItemsPerDay = DefaultHoldLimits.MaxItemsPerDay
	}
	return l
}

type holdRecord struct {
	ReportID     string    `json:"reportId"`
	HeldAt       time.Time `json:"heldAt"`
	ReleaseAfter time.Time `json:"releaseAfter"`
}

// HoldLifetime is the one year the statute asks for, counted from the day the hold begins.
func HoldLifetime(from time.Time) time.Time { return from.UTC().AddDate(1, 0, 0) }

func (s *Store) heldDir() string { return s.dir + heldSuffix }

func validReportID(id string) bool {
	if id == "" || len(id) > 128 {
		return false
	}
	for _, c := range id {
		if c < 0x21 || c > 0x7e {
			return false
		}
	}
	return true
}

// logAccess appends one event line. It never carries content, keys or client addresses.
func (s *Store) logAccess(event, id, detail string, now time.Time) error {
	f, err := os.OpenFile(filepath.Join(s.heldDir(), accessLog), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	line, _ := json.Marshal(map[string]string{"at": now.UTC().Format(time.RFC3339), "event": event, "id": id, "detail": detail})
	_, err = f.Write(append(line, '\n'))
	if closeErr := f.Close(); err == nil {
		err = closeErr
	}
	return err
}

// errNoSource means the file to copy was not there: the link had nothing left to hold under that name.
var errNoSource = errors.New("links: nothing to copy")

// copyFile copies src to a new file dst and syncs it, so the held copy is on disk before the live one goes.
func copyFile(dst, src string) error {
	in, err := os.Open(src)
	if errors.Is(err, os.ErrNotExist) {
		return errNoSource
	}
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	if err := out.Sync(); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

func writeFileSynced(path string, data []byte) error {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

func syncDir(path string) error {
	d, err := os.Open(path)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}

// Hold moves a reported link's stored content into the restricted directory for one year and takes the
// link down at once. fullLink is the link the abuse-material form sent, key included, or nil. Calling it
// again for a held id only finishes the takedown. A link that has already expired and been swept can still
// be held for its reported link alone.
//
// Hold is the public report path: it keeps at most MaxReportedLinks distinct links per item and refuses a
// new hold past the store's HoldLimits with ErrHoldCap.
func (s *Store) Hold(id, reportID string, fullLink []byte, now time.Time) error {
	return s.hold(id, reportID, fullLink, now, true)
}

// HoldByOwner is Hold for the owner's `hold` command: no caps, because the owner is the one who decides
// what is worth keeping once a cap has been reached.
func (s *Store) HoldByOwner(id, reportID string, fullLink []byte, now time.Time) error {
	return s.hold(id, reportID, fullLink, now, false)
}

func (s *Store) hold(id, reportID string, fullLink []byte, now time.Time, public bool) error {
	if !ValidID(id) {
		return ErrNotFound
	}
	if !validReportID(reportID) {
		return ErrBadReportID
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	src := filepath.Join(s.dir, id)
	if _, err := os.Stat(filepath.Join(src, "meta.json")); errors.Is(err, os.ErrNotExist) {
		return ErrNotFound
	} else if err != nil {
		return err
	}
	if err := os.MkdirAll(s.heldDir(), 0o700); err != nil {
		return err
	}
	final := filepath.Join(s.heldDir(), id)
	logErr := error(nil)
	if _, err := os.Stat(final); errors.Is(err, os.ErrNotExist) {
		if public {
			if reason, err := s.capReason(src, now); err != nil {
				return err
			} else if reason != "" {
				_ = s.logAccess("cap", id, reason, now)
				return fmt.Errorf("%w: %s", ErrHoldCap, reason)
			}
		}
		tmp, err := os.MkdirTemp(s.heldDir(), ".hold-")
		if err != nil {
			return err
		}
		defer os.RemoveAll(tmp)
		for _, name := range []string{"packet", previewFile} {
			if err := copyFile(filepath.Join(tmp, name), filepath.Join(src, name)); err != nil && !errors.Is(err, errNoSource) {
				return err
			}
		}
		// Links parked beside the content when the cap refused an earlier hold come first, then this run's.
		limit := ownerMaxReportedLinks
		if public {
			limit = MaxReportedLinks
		}
		var kept [][]byte
		add := func(link []byte) {
			for _, k := range kept {
				if bytes.Equal(k, link) {
					return
				}
			}
			if len(kept) < limit {
				kept = append(kept, link)
			}
		}
		for n := 1; n <= MaxReportedLinks; n++ {
			if data, err := os.ReadFile(filepath.Join(src, reportedLinkName(n))); err == nil {
				add(data)
			}
		}
		if len(fullLink) > 0 {
			add(fullLink)
		}
		for i, link := range kept {
			if err := writeFileSynced(filepath.Join(tmp, reportedLinkName(i+1)), link); err != nil {
				return err
			}
		}
		record, _ := json.Marshal(holdRecord{ReportID: reportID, HeldAt: now.UTC(), ReleaseAfter: HoldLifetime(now)})
		if err := writeFileSynced(filepath.Join(tmp, holdMeta), record); err != nil {
			return err
		}
		if err := syncDir(tmp); err != nil {
			return err
		}
		if err := os.Rename(tmp, final); err != nil {
			return err
		}
		if err := syncDir(s.heldDir()); err != nil {
			return err
		}
		logErr = s.logAccess("hold", id, "report "+reportID, now)
	} else if err != nil {
		return err
	} else if len(fullLink) > 0 {
		// A later run may bring a reported link the first run did not have, or a different one. It adds the
		// link and never changes the report id or the year.
		logErr = s.addReportedLink(final, id, reportID, fullLink, now, public)
	}
	// The held copy is safely on disk, so the link comes down even if the log line could not be written.
	if err := s.takedownLocked(id); err != nil {
		return err
	}
	return logErr
}

func reportedLinkName(n int) string {
	if n == 1 {
		return reportedRef
	}
	return fmt.Sprintf("%s-%d", reportedRef, n)
}

// addReportedLink keeps fullLink beside the ones already held for this item, unless it is a copy of one of
// them. Past the cap a public report's link is dropped and the access log says so (the owner's run keeps
// going up to ownerMaxReportedLinks). Each link is stored as received and never parsed or logged.
func (s *Store) addReportedLink(final, id, reportID string, fullLink []byte, now time.Time, public bool) error {
	limit := ownerMaxReportedLinks
	if public {
		limit = MaxReportedLinks
	}
	added, err := addLinkSlot(final, fullLink, limit)
	switch {
	case err == errSlotsFull:
		return s.logAccess("link-dropped", id, "report "+reportID, now)
	case err != nil:
		return err
	case added:
		return s.logAccess("add-link", id, "report "+reportID, now)
	}
	return nil
}

var errSlotsFull = errors.New("links: all reported-link slots are used")

// addLinkSlot writes link into the first free reported-link slot of dir, unless a slot already holds
// the same bytes. It reports whether it wrote one.
func addLinkSlot(dir string, link []byte, limit int) (bool, error) {
	for n := 1; n <= limit; n++ {
		path := filepath.Join(dir, reportedLinkName(n))
		data, err := os.ReadFile(path)
		if errors.Is(err, os.ErrNotExist) {
			if err := writeFileSynced(path, link); err != nil {
				return false, err
			}
			return true, syncDir(dir)
		}
		if err != nil {
			return false, err
		}
		if bytes.Equal(data, link) {
			return false, nil
		}
	}
	return false, errSlotsFull
}

// ParkLink keeps a reported full link beside a link's content, for a hold that was refused at a cap: the
// owner's later hold by hand then has the key as well as the ciphertext. It keeps up to MaxReportedLinks
// and drops the rest. The link goes away with the content.
func (s *Store) ParkLink(id string, fullLink []byte) error {
	if !ValidID(id) {
		return ErrNotFound
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, err := os.Stat(filepath.Join(s.dir, id, "meta.json")); errors.Is(err, os.ErrNotExist) {
		return ErrNotFound
	} else if err != nil {
		return err
	}
	if _, err := addLinkSlot(filepath.Join(s.dir, id), fullLink, MaxReportedLinks); err != nil && err != errSlotsFull {
		return err
	}
	return nil
}

// IsHeld says whether a hold already exists for id. A re-report of a held link begins no new hold.
func (s *Store) IsHeld(id string) bool {
	if !ValidID(id) {
		return false
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	_, err := os.Stat(filepath.Join(s.heldDir(), id))
	return err == nil
}

// capReason says which cap a new hold of the link at src would pass, or "" if none. It counts what is
// held now by reading names, sizes and hold dates only, never content.
func (s *Store) capReason(src string, now time.Time) (string, error) {
	limits := s.HoldLimits.withDefaults()
	entries, err := os.ReadDir(s.heldDir())
	if err != nil {
		return "", err
	}
	items, today := 0, 0
	var held int64
	for _, e := range entries {
		if !ValidID(e.Name()) {
			continue
		}
		items++
		for _, name := range []string{"packet", previewFile} {
			if info, err := os.Stat(filepath.Join(s.heldDir(), e.Name(), name)); err == nil {
				held += info.Size()
			}
		}
		// An unreadable record counts as today's: the cap errs toward refusing, never toward holding more.
		inToday := true
		if data, err := os.ReadFile(filepath.Join(s.heldDir(), e.Name(), holdMeta)); err == nil {
			var rec holdRecord
			if json.Unmarshal(data, &rec) == nil {
				inToday = sameUTCDay(rec.HeldAt, now)
			}
		}
		if inToday {
			today++
		}
	}
	var adding int64
	for _, name := range []string{"packet", previewFile} {
		if info, err := os.Stat(filepath.Join(src, name)); err == nil {
			adding += info.Size()
		}
	}
	switch {
	case items >= limits.MaxItems:
		return fmt.Sprintf("held items at the cap of %d", limits.MaxItems), nil
	case held+adding > limits.MaxBytes:
		return fmt.Sprintf("held bytes would pass the cap of %d", limits.MaxBytes), nil
	case today >= limits.MaxItemsPerDay:
		return fmt.Sprintf("new holds today at the cap of %d", limits.MaxItemsPerDay), nil
	}
	return "", nil
}

func sameUTCDay(a, b time.Time) bool {
	ay, am, ad := a.UTC().Date()
	by, bm, bd := b.UTC().Date()
	return ay == by && am == bm && ad == bd
}

// NoteHoldRefused writes the "cap" line for a hold the caller refused before calling Hold (a per-client
// limit). It carries the link id and the reason, never content, keys or client addresses.
func (s *Store) NoteHoldRefused(id, reason string, now time.Time) error {
	if !ValidID(id) {
		return ErrNotFound
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := os.MkdirAll(s.heldDir(), 0o700); err != nil {
		return err
	}
	return s.logAccess("cap", id, singleLine(reason), now)
}

// SweepHeld deletes every held item whose year is up and logs each deletion. It returns how many it deleted.
func (s *Store) SweepHeld(now time.Time) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	entries, err := os.ReadDir(s.heldDir())
	if errors.Is(err, os.ErrNotExist) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	n := 0
	var firstErr error
	for _, e := range entries {
		if !ValidID(e.Name()) {
			// A crash mid-hold leaves a .hold- folder with a copy of the ciphertext and the reported link.
			// Clear it once it is an hour old, so no copy outlives the rules.
			if strings.HasPrefix(e.Name(), ".hold-") {
				if info, err := e.Info(); err == nil && now.Sub(info.ModTime()) >= time.Hour {
					if err := os.RemoveAll(filepath.Join(s.heldDir(), e.Name())); err != nil && firstErr == nil {
						firstErr = err
					}
				}
			}
			continue
		}
		// One unreadable record must not keep every later link past its year.
		due, err := s.holdDue(e.Name(), now)
		if err != nil {
			if firstErr == nil {
				firstErr = fmt.Errorf("held link %s: %w", e.Name(), err)
			}
			continue
		}
		if !due {
			continue
		}
		if err := s.deleteHeld(e.Name(), "year up", now); err != nil {
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		n++
	}
	return n, firstErr
}

func (s *Store) holdDue(id string, now time.Time) (bool, error) {
	data, err := os.ReadFile(filepath.Join(s.heldDir(), id, holdMeta))
	if err != nil {
		return false, err
	}
	var rec holdRecord
	if err := json.Unmarshal(data, &rec); err != nil {
		return false, fmt.Errorf("links: unreadable hold record for %s: %w", id, err)
	}
	return !now.Before(rec.ReleaseAfter), nil
}

// ReleaseHeld ends a hold before its year is up and deletes the held copy, for a reason the owner states
// (a law-enforcement request, say). The reason goes in the access log.
func (s *Store) ReleaseHeld(id, reason string, now time.Time) error {
	if !ValidID(id) {
		return ErrNotFound
	}
	if reason == "" {
		return ErrNoReason
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, err := os.Stat(filepath.Join(s.heldDir(), id)); errors.Is(err, os.ErrNotExist) {
		return ErrNotHeld
	} else if err != nil {
		return err
	}
	return s.deleteHeld(id, reason, now)
}

// deleteHeld writes the log line first, so a deletion always has its record; a crash between the two
// leaves a line and a folder, and the next sweep or release finishes the job.
func (s *Store) deleteHeld(id, why string, now time.Time) error {
	if err := s.logAccess("delete", id, singleLine(why), now); err != nil {
		return err
	}
	return os.RemoveAll(filepath.Join(s.heldDir(), id))
}

func singleLine(text string) string {
	out := make([]rune, 0, len(text))
	for _, c := range text {
		if c == '\n' || c == '\r' {
			c = ' '
		}
		out = append(out, c)
	}
	if len(out) > 200 {
		out = out[:200]
	}
	return string(out)
}

// HeldIDs lists the ids currently held, for the owner's runbook check. It reads names only.
func (s *Store) HeldIDs() ([]string, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	entries, err := os.ReadDir(s.heldDir())
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var ids []string
	for _, e := range entries {
		if ValidID(e.Name()) {
			ids = append(ids, e.Name())
		}
	}
	return ids, nil
}

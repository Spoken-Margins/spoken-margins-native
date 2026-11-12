package clubs

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

	"spokenmargins.dev/bridge/internal/links"
)

// A club reported as abuse material is held for one year, as a reported share link is (#2235, 18 U.S.C.
// 2258A(h); docs/design/club-mailbox.md section 7 point 3). The held copy is a sibling of the clubs folder,
// <clubs>-held, mode 0700, so nothing that serves a club can reach it. Nobody opens held content: this
// package has no call that reads a held header or post. The one thing the owner can read back is the
// reported invite links (ReportedLinks), because the CyberTipline report needs the full link, and each
// read is logged.
//
// What is held is what the server already has: the sealed header, every sealed post and every disabled
// post, as stored, and the full invite link (key included) that the report sent, as received. The link is
// never parsed or logged here. The same rules as links.Store hold: Hold comes before the takedown, the
// public report path is capped, the owner's own run is not, and a hold begun again only adds links.
//
// Layout, per held club: header, posts/<n>, disabled/<n>, reported-link, reported-link-2 .. 5, hold.json.
const (
	heldSuffix  = "-held"
	holdMeta    = "hold.json"
	reportedRef = "reported-link"
	accessLog   = "access.log"
	// ownerMaxReportedLinks bounds the owner's own hold runs, which are not limited to links.MaxReportedLinks.
	ownerMaxReportedLinks = 64
)

var (
	// ErrBadReportID is returned when the CyberTipline report id is empty or has a character that could
	// break the one-line access log.
	ErrBadReportID = errors.New("clubs: bad report id")
	ErrNotHeld     = errors.New("clubs: not held")
	ErrNoReason    = errors.New("clubs: a release needs a stated reason")
	// ErrHoldCap is returned when a new hold would pass a cap. The club is not held and not taken down:
	// the caller parks it (Disable, ParkLink) so its content stays for the owner to hold by hand.
	ErrHoldCap = errors.New("clubs: hold cap reached")
)

// HoldLimits caps what the public report path can make this server keep for a year, with the same
// meaning and defaults as links.HoldLimits. The clubs folder has its own held folder, so its caps count
// its own holds.
func (s *Store) holdLimits() links.HoldLimits {
	l := s.HoldLimits
	d := links.DefaultHoldLimits
	if l.MaxItems <= 0 {
		l.MaxItems = d.MaxItems
	}
	if l.MaxBytes <= 0 {
		l.MaxBytes = d.MaxBytes
	}
	if l.MaxItemsPerDay <= 0 {
		l.MaxItemsPerDay = d.MaxItemsPerDay
	}
	return l
}

type holdRecord struct {
	ReportID     string    `json:"reportId"`
	HeldAt       time.Time `json:"heldAt"`
	ReleaseAfter time.Time `json:"releaseAfter"`
}

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

func reportedLinkName(n int) string {
	if n == 1 {
		return reportedRef
	}
	return fmt.Sprintf("%s-%d", reportedRef, n)
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

// copyFileSynced copies one plain file and syncs it, so the held copy is on disk before the live one goes.
func copyFileSynced(dst, src string) error {
	in, err := os.Open(src)
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

// copyPlainFiles copies every non-empty plain file of src into a new dst folder (an empty file is the
// place a disabled post left in posts/, with nothing to hold). A missing src copies nothing.
func copyPlainFiles(dst, src string) error {
	entries, err := os.ReadDir(src)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	made := false
	for _, e := range entries {
		info, err := e.Info()
		if err != nil || !info.Mode().IsRegular() || info.Size() == 0 {
			continue
		}
		if !made {
			if err := os.Mkdir(dst, 0o700); err != nil {
				return err
			}
			made = true
		}
		if err := copyFileSynced(filepath.Join(dst, e.Name()), filepath.Join(src, e.Name())); err != nil {
			return err
		}
	}
	if made {
		return syncDir(dst)
	}
	return nil
}

// Hold moves a reported club's stored content into the restricted folder for one year and ends the club
// at once. fullLink is the invite link the abuse-material form sent, key included, or nil. Calling it again
// for a held id only adds a link and finishes the takedown. A club that has already ended can still be held
// for its reported link alone.
//
// Hold is the public report path: it keeps at most links.MaxReportedLinks distinct links per club and
// refuses a new hold past HoldLimits with ErrHoldCap.
func (s *Store) Hold(id, reportID string, fullLink []byte, now time.Time) error {
	return s.hold(id, reportID, fullLink, now, true)
}

// HoldByOwner is Hold for the owner's command: no caps, because the owner decides what is worth keeping
// once a cap has been reached.
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
	m, err := s.readMeta(id)
	if err != nil {
		return err
	}
	src := s.path(id)
	if err := os.MkdirAll(s.heldDir(), 0o700); err != nil {
		return err
	}
	final := filepath.Join(s.heldDir(), id)
	limit := ownerMaxReportedLinks
	if public {
		limit = links.MaxReportedLinks
	}
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
		if m.State != stateGone {
			if err := copyPlainFilesNamed(tmp, src, "header"); err != nil {
				return err
			}
			for _, sub := range []string{"posts", "disabled"} {
				if err := copyPlainFiles(filepath.Join(tmp, sub), filepath.Join(src, sub)); err != nil {
					return err
				}
			}
		}
		// Links parked beside the content when the cap refused an earlier hold come first, then this run's.
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
		for n := 1; n <= links.MaxReportedLinks; n++ {
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
		record, _ := json.Marshal(holdRecord{ReportID: reportID, HeldAt: now.UTC(), ReleaseAfter: links.HoldLifetime(now)})
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
		// A later run may bring a link the first run did not have, or a different one. It adds the link and
		// never changes the report id or the year.
		added, err := addLinkSlot(final, fullLink, limit)
		switch {
		case errors.Is(err, errSlotsFull):
			logErr = s.logAccess("link-dropped", id, "report "+reportID, now)
		case err != nil:
			logErr = err
		case added:
			logErr = s.logAccess("add-link", id, "report "+reportID, now)
		}
	}
	// The held copy is safely on disk, so the club ends even if the log line could not be written.
	if err := s.endLocked(id, m, now); err != nil {
		return err
	}
	return logErr
}

// copyPlainFilesNamed copies the one named plain file of src into dst, if it is there.
func copyPlainFilesNamed(dst, src, name string) error {
	info, err := os.Lstat(filepath.Join(src, name))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return nil
	}
	return copyFileSynced(filepath.Join(dst, name), filepath.Join(src, name))
}

var errSlotsFull = errors.New("clubs: all reported-link slots are used")

// addLinkSlot writes link into the first free reported-link slot of dir, unless a slot already holds the
// same bytes. It reports whether it wrote one.
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

// ParkLink keeps a reported invite link beside a club's content, for a hold that was refused at a cap: the
// owner's later hold by hand then has the key as well as the ciphertext. It keeps up to
// links.MaxReportedLinks and drops the rest. The link goes away with the content.
func (s *Store) ParkLink(id string, fullLink []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, err := s.readMeta(id)
	if err != nil {
		return err
	}
	if m.State == stateGone {
		return ErrGone
	}
	if _, err := addLinkSlot(s.path(id), fullLink, links.MaxReportedLinks); err != nil && !errors.Is(err, errSlotsFull) {
		return err
	}
	return nil
}

// IsHeld says whether a hold already exists for id. A re-report of a held club begins no new hold.
func (s *Store) IsHeld(id string) bool {
	if !ValidID(id) {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.isHeld(id)
}

// EndedAndHeld says whether the club is held and has already ended: a hold that failed only at its last
// step (the log line) has still done its work.
func (s *Store) EndedAndHeld(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, err := s.readMeta(id)
	return err == nil && m.State == stateGone && s.isHeld(id)
}

func (s *Store) isHeld(id string) bool {
	if !ValidID(id) {
		return false
	}
	_, err := os.Stat(filepath.Join(s.heldDir(), id))
	return err == nil
}

// sizeOfContent is the bytes in a club's (or a held club's) header, posts and disabled posts.
func sizeOfContent(dir string) int64 {
	var n int64
	if info, err := os.Stat(filepath.Join(dir, "header")); err == nil {
		n += info.Size()
	}
	for _, sub := range []string{"posts", "disabled"} {
		entries, err := os.ReadDir(filepath.Join(dir, sub))
		if err != nil {
			continue
		}
		for _, e := range entries {
			if info, err := e.Info(); err == nil && info.Mode().IsRegular() {
				n += info.Size()
			}
		}
	}
	return n
}

// capReason says which cap a new hold of the club at src would pass, or "" if none. It counts what is
// held now by reading names, sizes and hold dates only, never content.
func (s *Store) capReason(src string, now time.Time) (string, error) {
	limits := s.holdLimits()
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
		held += sizeOfContent(filepath.Join(s.heldDir(), e.Name()))
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
	adding := sizeOfContent(src)
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
// limit). It carries the club id and the reason, never content, keys or client addresses.
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

// SweepHeld deletes every held club whose year is up and logs each deletion. It returns how many it deleted.
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
		// One unreadable record must not keep every later club past its year.
		due, err := s.holdDue(e.Name(), now)
		if err != nil {
			if firstErr == nil {
				firstErr = fmt.Errorf("held club %s: %w", e.Name(), err)
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
		return false, fmt.Errorf("clubs: unreadable hold record for %s: %w", id, err)
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

// ReportedLinks returns the reported invite links kept for a held club, in the order they were kept, so the
// owner can put them in the CyberTipline report without opening the content. It reads only the
// reported-link files: never the header, the posts or hold.json. The read is logged before the links are
// returned, so a read always has its record, and a log that cannot be written means no links are returned.
func (s *Store) ReportedLinks(id string, now time.Time) ([][]byte, error) {
	if !ValidID(id) {
		return nil, ErrNotFound
	}
	s.mu.Lock() // the log line is a write
	defer s.mu.Unlock()
	dir := filepath.Join(s.heldDir(), id)
	if info, err := os.Lstat(dir); errors.Is(err, os.ErrNotExist) {
		return nil, ErrNotHeld
	} else if err != nil {
		return nil, err
	} else if !info.IsDir() {
		return nil, ErrNotHeld
	}
	var found [][]byte
	for n := 1; n <= ownerMaxReportedLinks; n++ {
		path := filepath.Join(dir, reportedLinkName(n))
		info, err := os.Lstat(path)
		if errors.Is(err, os.ErrNotExist) {
			break
		}
		if err != nil {
			return nil, err
		}
		// A slot is a plain file the hold wrote. A link to another file is never followed.
		if !info.Mode().IsRegular() {
			return nil, fmt.Errorf("clubs: %s is not a plain file", reportedLinkName(n))
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		found = append(found, data)
	}
	if err := s.logAccess("show-reported-link", id, fmt.Sprintf("%d links", len(found)), now); err != nil {
		return nil, err
	}
	return found, nil
}

// HeldIDs lists the club ids currently held, for the owner's runbook check. It reads names only.
func (s *Store) HeldIDs() ([]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
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

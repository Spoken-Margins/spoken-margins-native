package clubs

import (
	"errors"
	"os"
	"strconv"
	"time"
)

// Reports and the owner's takedowns (#1799, docs/design/club-mailbox.md section 7). Nobody reads a club,
// so every step here works blind: it moves or marks bytes and never looks at them.

// DisablePost stops one post being served, for the member who reported it: the request carries the
// club's read proof, so someone who only saw a club id in a link preview cannot silence posts. The
// post's bytes move to disabled/<n> and stay until the club ends, so a hold can still be made by hand;
// its place in posts/ becomes an empty file, so the numbers keep no gaps and a later post never takes
// the number. Doing it again changes nothing. A wrong or missing proof, an unknown club and a bad id
// answer ErrNotFound alike; a club that has ended or was disabled answers ErrGone to a member; a post
// number that is not in the box is ErrNotFound.
func (s *Store) DisablePost(id, readProof string, seq int, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, err := s.access(id, Read, readProof, now); err != nil {
		return err
	}
	return s.disablePostLocked(id, seq, now)
}

// DisablePostByOwner is DisablePost for the owner's command line, which holds no proof. It works on a
// club that is disabled too, and refuses a club that has ended (its content is gone).
func (s *Store) DisablePostByOwner(id string, seq int, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, err := s.readMeta(id)
	if err != nil {
		return err
	}
	if m.State == stateGone {
		return ErrGone
	}
	return s.disablePostLocked(id, seq, now)
}

func (s *Store) disablePostLocked(id string, seq int, now time.Time) error {
	if seq < 1 {
		return ErrNotFound
	}
	name := strconv.Itoa(seq)
	src := s.path(id, "posts", name)
	info, err := os.Lstat(src)
	if errors.Is(err, os.ErrNotExist) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if info.Size() == 0 {
		return nil // already disabled
	}
	day := dayOf(now)
	if err := os.MkdirAll(s.path(id, "disabled"), 0o700); err != nil {
		return err
	}
	dst := s.path(id, "disabled", name)
	// Link first and replace second: a crash between the two leaves the post still served and its bytes
	// kept, so the report can simply be made again. Never a gap in the numbers.
	if err := os.Link(src, dst); err != nil && !errors.Is(err, os.ErrExist) {
		return err
	}
	tmp, err := os.CreateTemp(s.path(id), ".post-")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmp.Name(), 0o600); err != nil {
		return err
	}
	setTimes(day, tmp.Name())
	if err := os.Rename(tmp.Name(), src); err != nil {
		return err
	}
	setTimes(day, s.path(id, "disabled"), s.path(id, "posts"), s.path(id))
	return nil
}

// Status says what a reported club is now, for the owner's `reports` list: "no such club", "taken down",
// "disabled", "STILL SERVED", each with ", held" when its hold exists, and for a report that named a post
// (post > 0) whether that post is down. "STILL SERVED" means the report did not stop it.
func (s *Store) Status(id string, post int, now time.Time) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, err := s.readMeta(id)
	if errors.Is(err, ErrNotFound) {
		return "no such club"
	}
	if err != nil {
		return "unknown (" + err.Error() + ")"
	}
	held := ""
	if s.isHeld(id) {
		held = ", held"
	}
	switch {
	case m.State == stateGone:
		return "taken down" + held
	case m.State == stateDisabled:
		return "disabled" + held
	case s.expired(id, m, now):
		return "expired" + held
	}
	if post > 0 {
		info, err := os.Lstat(s.path(id, "posts", strconv.Itoa(post)))
		switch {
		case errors.Is(err, os.ErrNotExist):
			return "no such post, club STILL SERVED" + held
		case err == nil && info.Size() == 0:
			return "post disabled" + held
		}
		return "post STILL SERVED" + held
	}
	return "STILL SERVED" + held
}

// Reportable says whether a report may be filed about club id: ErrNotFound for an id that is not a club,
// for a club that has ended (unless allowEnded, which an abuse-material report needs so its link can still
// be held) and for a live club past its lifetime that no sweep has ended yet. A disabled club is
// reportable: a second report only repeats the first. It carries no proof, so a whole-club report needs
// only the id, as a link report does (docs/design/club-mailbox.md section 7 point 2).
func (s *Store) Reportable(id string, now time.Time, allowEnded bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, err := s.readMeta(id)
	if err != nil {
		return err
	}
	if m.State == stateGone {
		if allowEnded {
			return nil
		}
		return ErrNotFound
	}
	if m.State == "" && s.expired(id, m, now) && !allowEnded {
		return ErrNotFound
	}
	return nil
}

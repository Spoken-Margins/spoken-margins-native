package clubs

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"

	"spokenmargins.dev/bridge/internal/links"
)

// Reply boxes (#4675, docs/design/reply-mailbox.md). A reply box is a club of two that the sender's phone
// makes with each share link: a friend who opens the link in a browser posts an answer into it with the
// post proof the link's sealed reply part carries, and only the sender's phone, which keeps the read proof,
// can list and fetch what arrived. It is a club in every way the store does not list here:
//
//   - It is made with the link (CreateReply), never by POST /api/v1/clubs, and has no sealed header, so
//     item 0 is "not found".
//   - It takes posts until its link's expiry (postsUntil), and the server's API also refuses posts once the
//     link has been taken down or held. Its sender can read for ReplyReadDays more, then it ends. The
//     clubs' 7-day first-post rule and 90-day idle rule do not apply: a box nobody answers is normal.
//   - Its caps are smaller: ReplyMaxPosts posts, ReplyMaxBoxBytes, ReplyMaxPostBytes a post. Its bytes
//     count against the clubs' one pool.
//   - Its sender can close it (Close, with the read proof): it takes no more posts, and reads and reports
//     still work until it ends.
//
// On disk it is a club's folder without the header: meta.json (kind "reply", the link id and postsUntil
// beside the club fields), posts/<n>, and disabled/<n> or reported-link files after a report.
const (
	ReplyMaxPosts           = 20
	ReplyMaxBoxBytes  int64 = 50 << 20
	ReplyMaxPostBytes       = 10 << 20
	// ReplyReadDays is how long the sender may still collect answers after the link ends.
	ReplyReadDays = 7

	kindReply = "reply"
)

// BoxInfo is what the API needs to know about a box before it checks a proof: which switch governs it,
// and, for a reply box, which link it belongs to. It never leaves the server.
type BoxInfo struct {
	Exists bool
	Reply  bool
	LinkID string
}

// Box says what id is, without a proof. A malformed or unknown id is a BoxInfo with Exists false.
func (s *Store) Box(id string) BoxInfo {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, err := s.readMeta(id)
	if err != nil {
		return BoxInfo{}
	}
	return BoxInfo{Exists: true, Reply: m.Kind == kindReply, LinkID: m.LinkID}
}

func postsUntil(m metadata) time.Time {
	t, err := time.Parse(time.RFC3339, m.PostsUntil)
	if err != nil {
		return time.Time{}
	}
	return t
}

func readsUntil(m metadata) time.Time {
	return postsUntil(m).AddDate(0, 0, ReplyReadDays)
}

// takesPosts is false for a reply box that was closed or whose link has expired. A club always takes them
// (its own rules end it).
func takesPosts(m metadata, now time.Time) bool {
	if m.Kind != kindReply {
		return true
	}
	return m.State != stateClosed && now.Before(postsUntil(m))
}

// caps are a box's own limits: posts, bytes held and bytes in one post.
func (s *Store) caps(m metadata) (int, int64, int) {
	if m.Kind == kindReply {
		return ReplyMaxPosts, ReplyMaxBoxBytes, ReplyMaxPostBytes
	}
	return s.Limits.posts(), s.Limits.club(), MaxPostBytes
}

// CreateReply makes a reply box for the share link linkID, from what the sender's phone sent with the
// link: the box id and the hashes of its read and post proofs. It takes posts until postsUntil, the link's
// expiry. An id that already exists, as a club or a box, is ErrConflict: a box belongs to one link.
func (s *Store) CreateReply(id, readHash, postHash, linkID string, until, now time.Time) error {
	if !ValidID(id) || !ValidHash(readHash) || !ValidHash(postHash) || readHash == postHash || !links.ValidID(linkID) || !until.After(now) {
		return ErrInvalid
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, err := s.readMeta(id); err == nil {
		return ErrConflict
	} else if !errors.Is(err, ErrNotFound) {
		return err
	}
	tmp, err := os.MkdirTemp(s.dir, ".club-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)
	if err := os.Mkdir(filepath.Join(tmp, "posts"), 0o700); err != nil {
		return err
	}
	day := dayOf(now)
	meta, _ := json.Marshal(metadata{
		ReadHash: readHash, PostHash: postHash, CreatedDay: day.Format(dayFormat), LastActiveDay: day.Format(dayFormat),
		Kind: kindReply, LinkID: linkID, PostsUntil: until.UTC().Format(time.RFC3339),
	})
	if err := os.WriteFile(filepath.Join(tmp, "meta.json"), meta, 0o600); err != nil {
		return err
	}
	setTimes(day, filepath.Join(tmp, "meta.json"), filepath.Join(tmp, "posts"), tmp)
	if err := os.Rename(tmp, s.path(id)); err != nil {
		return err
	}
	setTimes(day, s.path(id), s.dir)
	return nil
}

// DiscardReply removes a reply box that was made for linkID but never announced, because the link's reply
// part could not be stored. It leaves no tombstone, since nobody was ever told of the box, and it refuses
// anything that is not that box or has had a post.
func (s *Store) DiscardReply(id, linkID string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, err := s.readMeta(id)
	if err != nil {
		return err
	}
	if m.Kind != kindReply || m.LinkID != linkID || m.State != "" {
		return ErrNotFound
	}
	if _, _, count := s.posts(id); count > 0 {
		return ErrConflict
	}
	if err := os.RemoveAll(s.path(id)); err != nil {
		return err
	}
	setTimes(dayOf(now), s.dir)
	return nil
}

// Close stops a reply box taking posts, for its sender, who alone holds the read proof. A post proof, a
// wrong or missing proof, an unknown id and a club (not a reply box) all answer ErrNotFound. A box that
// is already closed, disabled or ended counts as closed: nil.
func (s *Store) Close(id, readProof string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, err := s.readMeta(id)
	if errors.Is(err, ErrNotFound) {
		matches(noClub, Read, readProof)
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if !matches(m, Read, readProof) || m.Kind != kindReply {
		return ErrNotFound
	}
	if m.State != "" || s.expired(id, m, now) {
		return nil
	}
	m.State = stateClosed
	return s.writeMeta(id, m, dayOf(now))
}

// ReplyCounts is the owner's closed-loop measure (`smserver replies count`): how many reply boxes the
// store holds now, and how many of them have had at least one answer. A box that has ended keeps no posts,
// so both numbers cover only boxes still within their link's life and the seven days after. It names no
// box and stores nothing.
func (s *Store) ReplyCounts(now time.Time) (boxes, answered int, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return 0, 0, err
	}
	for _, e := range entries {
		if !ValidID(e.Name()) {
			continue
		}
		m, err := s.readMeta(e.Name())
		if err != nil || m.Kind != kindReply || m.State == stateGone || s.expired(e.Name(), m, now) {
			continue
		}
		boxes++
		if _, _, count := s.posts(e.Name()); count > 0 {
			answered++
		}
	}
	return boxes, answered, nil
}

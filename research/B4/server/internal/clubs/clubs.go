// Package clubs stores club mailboxes: a box of sealed packets that every member of a club can read
// and add to (#1799, docs/design/club-mailbox.md).
//
// The server holds the box and never the key. A club's key K is made on the creator's phone and
// travels only in the invite link's # part. The phone derives four values from it: the club id, a
// read proof, a post proof and a sealing key. The server is given the id and the SHA-256 of the two
// proofs when the club is made, so it can tell a member from a stranger without knowing K, and it
// stores each post's bytes exactly as they came. It never decodes, reorders or merges them.
//
// On disk, for each club, and nothing else:
//
//	<id>/meta.json   the two proof hashes, the days it was made and last used, and an optional state
//	<id>/header      the sealed header (item 0 of the box: the club's name, sealed)
//	<id>/posts/<n>   the sealed posts, numbered from 1 with no gaps
//
// Times are days, never instants: meta.json holds days and every file and folder time is set to
// midnight UTC, so neither the contents nor the file system say when in a day anyone posted or
// read. There is no member list, no name, no address and no install identity here.
//
// A club that expires or is taken down keeps only its meta.json, marked "gone", so its id cannot
// be made again and a member who still holds the proof is told it is gone. Anyone else, and anyone
// with a wrong or missing proof, is told "not found", the same as for an id that never existed.
package clubs

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"sync"
	"time"

	"spokenmargins.dev/bridge/internal/links"
)

const (
	// MaxPostBytes is the same as a share link's packet.
	MaxPostBytes = links.MaxPacketBytes
	// MaxHeaderBytes bounds the sealed header (a name and a label).
	MaxHeaderBytes = 16 << 10

	DefaultMaxPosts            = 200
	DefaultMaxClubBytes  int64 = 200 << 20
	DefaultMaxTotalBytes int64 = 5 << 30

	// FirstPostDays is how long a club may stay empty. IdleDays is how long a club that has had a post
	// may go with no post and no read.
	FirstPostDays = 7
	IdleDays      = 90

	dayFormat = "2006-01-02"

	// ProofHexLen and HashHexLen are the written length of a 32-byte proof and of its SHA-256.
	ProofHexLen = 64
	HashHexLen  = 64
)

var (
	// ErrNotFound answers an id that does not exist, a wrong or missing proof, and a bad id alike.
	ErrNotFound = errors.New("clubs: not found")
	// ErrGone answers only a request that carried a valid proof for a club that has ended or was disabled.
	ErrGone = errors.New("clubs: gone")
	// ErrConflict answers a create for an id that exists with other proof hashes.
	ErrConflict = errors.New("clubs: id in use")
	// ErrInvalid is a create whose id, hashes or header are malformed.
	ErrInvalid  = errors.New("clubs: invalid request")
	ErrTooLarge = errors.New("clubs: too large")
	ErrUnsealed = errors.New("clubs: not a sealed part")
	// ErrClubFull is the club's own cap (posts or bytes). ErrFull is the whole clubs folder's cap.
	ErrClubFull = errors.New("clubs: club full")
	ErrFull     = errors.New("clubs: full")
)

// Limits are the caps. Zero fields mean the defaults.
type Limits struct {
	MaxPosts      int
	MaxClubBytes  int64
	MaxTotalBytes int64
}

func (l Limits) posts() int {
	if l.MaxPosts <= 0 {
		return DefaultMaxPosts
	}
	return l.MaxPosts
}
func (l Limits) club() int64 {
	if l.MaxClubBytes <= 0 {
		return DefaultMaxClubBytes
	}
	return l.MaxClubBytes
}
func (l Limits) total() int64 {
	if l.MaxTotalBytes <= 0 {
		return DefaultMaxTotalBytes
	}
	return l.MaxTotalBytes
}

// Kind is which proof a request carries.
type Kind int

const (
	Read Kind = iota
	Post
)

type metadata struct {
	ReadHash      string `json:"readHash"`
	PostHash      string `json:"postHash"`
	CreatedDay    string `json:"createdDay"`
	LastActiveDay string `json:"lastActiveDay"`
	// State is "" for a live club, "disabled" while it is not served but its content stays, "gone" once
	// the content is deleted.
	State string `json:"state,omitempty"`
}

const (
	stateDisabled = "disabled"
	stateGone     = "gone"
)

// PostInfo is one row of a club's list.
type PostInfo struct {
	Seq  int   `json:"seq"`
	Size int64 `json:"size"`
}

type Store struct {
	dir    string
	Limits Limits
	mu     sync.Mutex
	// total is the bytes held in every live club. It is counted when the store opens and kept as
	// posts arrive and clubs end, so a cap needs no walk.
	total int64
}

// OpenStore opens (and makes) the clubs folder and counts what it already holds.
func OpenStore(dir string) (*Store, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	s := &Store{dir: dir}
	if _, err := os.ReadDir(dir); err != nil {
		return nil, err
	}
	s.recount()
	return s, nil
}

// ValidID reports whether id is 32 lowercase hex digits, the 16 bytes a phone derives from the key.
func ValidID(id string) bool { return lowerHex(id, 32) }

// ValidHash reports whether h is a written SHA-256.
func ValidHash(h string) bool { return lowerHex(h, HashHexLen) }

func lowerHex(s string, n int) bool {
	if len(s) != n {
		return false
	}
	for _, c := range s {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// HashProof is the SHA-256 the server stores for a proof, both written as lowercase hex. It is the
// function a phone applies to a proof when it makes a club.
func HashProof(proof string) (string, bool) {
	if !lowerHex(proof, ProofHexLen) {
		return "", false
	}
	raw, err := hex.DecodeString(proof)
	if err != nil {
		return "", false
	}
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:]), true
}

func dayOf(t time.Time) time.Time {
	t = t.UTC()
	return time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, time.UTC)
}

func (s *Store) path(id string, rest ...string) string {
	return filepath.Join(append([]string{s.dir, id}, rest...)...)
}

func (s *Store) readMeta(id string) (metadata, error) {
	var m metadata
	if !ValidID(id) {
		return m, ErrNotFound
	}
	data, err := os.ReadFile(s.path(id, "meta.json"))
	if errors.Is(err, os.ErrNotExist) {
		return m, ErrNotFound
	}
	if err != nil {
		return m, err
	}
	return m, json.Unmarshal(data, &m)
}

// writeMeta replaces meta.json atomically and sets its time to midnight of day.
func (s *Store) writeMeta(id string, m metadata, day time.Time) error {
	dir := s.path(id)
	f, err := os.CreateTemp(dir, ".meta-")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	data, _ := json.Marshal(m)
	_, err = f.Write(data)
	if closeErr := f.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	if err := os.Rename(f.Name(), s.path(id, "meta.json")); err != nil {
		return err
	}
	setTimes(day, s.path(id, "meta.json"), dir)
	return nil
}

func setTimes(day time.Time, paths ...string) {
	for _, p := range paths {
		os.Chtimes(p, day, day)
	}
}

// matches reports whether proof is the club's proof of the given kind. A well-formed proof does one
// SHA-256 and one constant-time comparison whether the club exists or not, so a wrong proof and an unknown
// club take the same time. A malformed proof skips the hash, but it does so for an existing club and an
// unknown id alike, so it says nothing about which ids are clubs.
func matches(m metadata, kind Kind, proof string) bool {
	got, ok := HashProof(proof)
	want := m.ReadHash
	if kind == Post {
		want = m.PostHash
	}
	if !ok {
		got = string(make([]byte, HashHexLen))
	}
	equal := subtle.ConstantTimeCompare([]byte(got), []byte(want)) == 1
	return ok && equal
}

var noClub = metadata{ReadHash: string(make([]byte, HashHexLen)), PostHash: string(make([]byte, HashHexLen))}

// access is the one gate every read and post goes through, with s.mu held. It answers ErrNotFound to
// anyone without the club's proof, and ErrGone only to someone who has it.
func (s *Store) access(id string, kind Kind, proof string, now time.Time) (metadata, error) {
	m, err := s.readMeta(id)
	if errors.Is(err, ErrNotFound) {
		matches(noClub, kind, proof)
		return m, ErrNotFound
	}
	if err != nil {
		return m, err
	}
	if !matches(m, kind, proof) {
		return m, ErrNotFound
	}
	if m.State != "" || s.expired(id, m, now) {
		return m, ErrGone
	}
	return m, nil
}

// expired is the lifetime rule: a club with no post seven days after it was made, or no post and no read
// for ninety days, has ended. Days, not instants.
func (s *Store) expired(id string, m metadata, now time.Time) bool {
	today := dayOf(now)
	if last, err := time.Parse(dayFormat, m.LastActiveDay); err != nil || !today.Before(last.AddDate(0, 0, IdleDays)) {
		return true
	}
	created, err := time.Parse(dayFormat, m.CreatedDay)
	if err != nil {
		return true
	}
	if !today.Before(created.AddDate(0, 0, FirstPostDays)) {
		if _, _, count := s.posts(id); count == 0 {
			return true
		}
	}
	return false
}

// posts lists the post files in order, with the highest number and the bytes they hold.
func (s *Store) posts(id string) (infos []PostInfo, bytesHeld int64, count int) {
	entries, err := os.ReadDir(s.path(id, "posts"))
	if err != nil {
		return nil, 0, 0
	}
	for _, e := range entries {
		n, err := strconv.Atoi(e.Name())
		if err != nil || n < 1 || strconv.Itoa(n) != e.Name() {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		infos = append(infos, PostInfo{Seq: n, Size: info.Size()})
		bytesHeld += info.Size()
	}
	sort.Slice(infos, func(i, j int) bool { return infos[i].Seq < infos[j].Seq })
	return infos, bytesHeld, len(infos)
}

// contentBytes is what a club's header and posts hold.
func (s *Store) contentBytes(id string) int64 {
	var n int64
	if info, err := os.Stat(s.path(id, "header")); err == nil {
		n += info.Size()
	}
	_, held, _ := s.posts(id)
	return n + held
}

// touch records that the club was used today. Only the day is kept, and the file is written only when
// the day changes.
func (s *Store) touch(id string, m metadata, now time.Time) error {
	today := dayOf(now)
	if last, err := time.Parse(dayFormat, m.LastActiveDay); err == nil && !today.After(last) {
		return nil
	}
	m.LastActiveDay = today.Format(dayFormat)
	return s.writeMeta(id, m, today)
}

// Create makes a club from what the creator's phone sends: the id, the hashes of the two proofs and the
// sealed header. It reports whether it made one. A repeat with the same id and the same hashes is not an
// error and changes nothing, so a retry after a lost answer works; the same id with other hashes is
// ErrConflict. The id is 128 bits, so that answer tells a stranger nothing they could not guess.
func (s *Store) Create(id, readHash, postHash string, header []byte, now time.Time) (bool, error) {
	// The two proofs are different values; one hash for both would make a read proof a post proof.
	if !ValidID(id) || !ValidHash(readHash) || !ValidHash(postHash) || readHash == postHash || len(header) == 0 {
		return false, ErrInvalid
	}
	if len(header) > MaxHeaderBytes {
		return false, ErrTooLarge
	}
	if !links.Sealed(header, links.PartClubHeader) {
		return false, ErrUnsealed
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if m, err := s.readMeta(id); err == nil {
		if subtle.ConstantTimeCompare([]byte(m.ReadHash+m.PostHash), []byte(readHash+postHash)) != 1 {
			return false, ErrConflict
		}
		if m.State != "" || s.expired(id, m, now) {
			return false, ErrGone
		}
		return false, nil
	} else if !errors.Is(err, ErrNotFound) {
		return false, err
	}
	if s.total+int64(len(header)) > s.Limits.total() {
		return false, ErrFull
	}
	tmp, err := os.MkdirTemp(s.dir, ".club-")
	if err != nil {
		return false, err
	}
	defer os.RemoveAll(tmp)
	if err := os.Mkdir(filepath.Join(tmp, "posts"), 0o700); err != nil {
		return false, err
	}
	day := dayOf(now)
	meta, _ := json.Marshal(metadata{ReadHash: readHash, PostHash: postHash, CreatedDay: day.Format(dayFormat), LastActiveDay: day.Format(dayFormat)})
	for name, data := range map[string][]byte{"meta.json": meta, "header": header} {
		if err := os.WriteFile(filepath.Join(tmp, name), data, 0o600); err != nil {
			return false, err
		}
	}
	setTimes(day, filepath.Join(tmp, "meta.json"), filepath.Join(tmp, "header"), filepath.Join(tmp, "posts"), tmp)
	if err := os.Rename(tmp, s.path(id)); err != nil {
		return false, err
	}
	// Making and moving the folder changed the clubs folder's own time; put it back to the day.
	setTimes(day, s.path(id), s.dir)
	s.total += int64(len(header))
	return true, nil
}

// Check says whether the proof opens the club now, without using it or reading anything. The server asks
// before it reads a request's body, so a stranger cannot make it buffer 20 MB.
func (s *Store) Check(id string, kind Kind, proof string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.access(id, kind, proof, now)
	return err
}

// Post adds one sealed packet to the club and returns its number. Numbers start at 1 and have no gaps.
func (s *Store) Post(id, postProof string, packet []byte, now time.Time) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, err := s.access(id, Post, postProof, now)
	if err != nil {
		return 0, err
	}
	if len(packet) == 0 {
		return 0, ErrUnsealed
	}
	if len(packet) > MaxPostBytes {
		return 0, ErrTooLarge
	}
	if !links.Sealed(packet, links.PartPacket) {
		return 0, ErrUnsealed
	}
	infos, held, count := s.posts(id)
	size := int64(len(packet))
	if count >= s.Limits.posts() || held+size > s.Limits.club() {
		return 0, ErrClubFull
	}
	if s.total+size > s.Limits.total() {
		return 0, ErrFull
	}
	seq := 1
	if count > 0 {
		seq = infos[count-1].Seq + 1
	}
	f, err := os.CreateTemp(s.path(id), ".post-")
	if err != nil {
		return 0, err
	}
	defer os.Remove(f.Name())
	_, err = f.Write(packet)
	if closeErr := f.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return 0, err
	}
	if err := os.Chmod(f.Name(), 0o600); err != nil {
		return 0, err
	}
	today := dayOf(now)
	dest := s.path(id, "posts", strconv.Itoa(seq))
	setTimes(today, f.Name())
	if err := os.Rename(f.Name(), dest); err != nil {
		return 0, err
	}
	setTimes(today, s.path(id, "posts"), s.path(id))
	s.total += size
	if err := s.touch(id, m, now); err != nil {
		// The post is in. A failed day mark only means the club may expire a day early; the next
		// read or post marks it.
		return seq, nil
	}
	return seq, nil
}

// List is the posts after number `after`, in order. It counts as a read.
func (s *Store) List(id, readProof string, after int, now time.Time) ([]PostInfo, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, err := s.access(id, Read, readProof, now)
	if err != nil {
		return nil, err
	}
	s.touch(id, m, now)
	infos, _, _ := s.posts(id)
	out := []PostInfo{}
	for _, p := range infos {
		if p.Seq > after {
			out = append(out, p)
		}
	}
	return out, nil
}

// Item opens one item of the box for reading: number 0 is the sealed header, 1 and up are the posts. It
// opens a real file, so serving it does not buffer another 20 MB, and it counts as a read.
func (s *Store) Item(id, readProof string, seq int, now time.Time) (*os.File, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, err := s.access(id, Read, readProof, now)
	if err != nil {
		return nil, err
	}
	s.touch(id, m, now)
	name := s.path(id, "header")
	if seq > 0 {
		name = s.path(id, "posts", strconv.Itoa(seq))
	} else if seq < 0 {
		return nil, ErrNotFound
	}
	f, err := os.Open(name)
	if errors.Is(err, os.ErrNotExist) {
		return nil, ErrNotFound
	}
	return f, err
}

// Disable stops a club being served, for every request, and keeps its content until the club's own
// lifetime ends, so a hold can still be made by hand. A member with the proof is told it is gone.
func (s *Store) Disable(id string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, err := s.readMeta(id)
	if err != nil {
		return err
	}
	if m.State != "" {
		return nil
	}
	m.State = stateDisabled
	return s.writeMeta(id, m, dayOf(now))
}

// Takedown ends a club at once: the tombstone is published before the content is deleted, so every
// later request is refused. It works from a separate command-line process too.
func (s *Store) Takedown(id string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, err := s.readMeta(id)
	if err != nil {
		return err
	}
	return s.endLocked(id, m, now)
}

func (s *Store) endLocked(id string, m metadata, now time.Time) error {
	if m.State != stateGone {
		// The bytes stop counting the moment the tombstone is published: that is also how a restart reads
		// the folder, so a failure below cannot leave the counter and the disk disagreeing for good.
		held := s.contentBytes(id)
		m.State = stateGone
		if err := s.writeMeta(id, m, dayOf(now)); err != nil {
			return err
		}
		s.total -= held
		if s.total < 0 {
			s.total = 0
		}
	}
	return s.removeContent(id, now)
}

// removeContent deletes a club's header and posts. It is also how Sweep finishes a takedown that was
// interrupted after its tombstone was written.
func (s *Store) removeContent(id string, now time.Time) error {
	if err := os.Remove(s.path(id, "header")); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if err := os.RemoveAll(s.path(id, "posts")); err != nil {
		return err
	}
	// Removing files changes the folder's own time; put it back to the day.
	setTimes(dayOf(now), s.path(id))
	return nil
}

// Sweep ends every club whose lifetime is over and clears what an interrupted write left behind. A club
// that is gone keeps its tombstone. It returns how many clubs it ended.
func (s *Store) Sweep(now time.Time) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return 0, err
	}
	n := 0
	for _, e := range entries {
		if !ValidID(e.Name()) {
			if info, err := e.Info(); err == nil && now.Sub(info.ModTime()) >= time.Hour {
				if err := os.RemoveAll(s.path(e.Name())); err != nil {
					return n, err
				}
				setTimes(dayOf(now), s.dir)
			}
			continue
		}
		m, err := s.readMeta(e.Name())
		if err != nil {
			continue
		}
		if m.State == stateGone {
			// A takedown interrupted after its tombstone leaves content behind; finish it.
			if err := s.removeContent(e.Name(), now); err != nil {
				return n, err
			}
			continue
		}
		s.sweepTemps(e.Name(), now)
		if s.expired(e.Name(), m, now) {
			if err := s.endLocked(e.Name(), m, now); err != nil {
				return n, err
			}
			n++
		}
	}
	// A takedown from the command line is another process, so this one's counter does not see it. Count the
	// folder again, once a day, so the cap follows the disk.
	s.recount()
	return n, nil
}

// recount sets the total from the disk.
func (s *Store) recount() {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return
	}
	var total int64
	for _, e := range entries {
		if !ValidID(e.Name()) {
			continue
		}
		if m, err := s.readMeta(e.Name()); err == nil && m.State != stateGone {
			total += s.contentBytes(e.Name())
		}
	}
	s.total = total
}

// sweepTemps removes post and meta temp files older than an hour, left by a crash mid-write.
func (s *Store) sweepTemps(id string, now time.Time) {
	entries, err := os.ReadDir(s.path(id))
	if err != nil {
		return
	}
	for _, e := range entries {
		if e.IsDir() || (e.Name() != "" && e.Name()[0] != '.') {
			continue
		}
		if info, err := e.Info(); err == nil && now.Sub(info.ModTime()) >= time.Hour {
			os.Remove(s.path(id, e.Name()))
		}
	}
}

// Total is the bytes held in live clubs, for the owner's read.
func (s *Store) Total() int64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.total
}

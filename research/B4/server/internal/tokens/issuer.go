package tokens

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// MaxPerRequest is the most blinded messages one issuance request may carry.
const MaxPerRequest = 10

var (
	ErrStaleKey     = errors.New("tokens: not the current signing key")
	ErrUnknownKey   = errors.New("tokens: unknown or expired key")
	ErrWrongPurpose = errors.New("tokens: token was made for another purpose")
	ErrSpent        = errors.New("tokens: token already spent")
	ErrTooMany      = errors.New("tokens: too many blinded messages")
)

// Issuer keeps one signing key per UTC month under dir/keys and the spent
// tokens of each month under dir/spent. A month's key signs during that
// month and its tokens are accepted until the end of the next one, so the
// spent records of a month can go once its key expires.
//
// The issuer never records which install received which signature: it
// signs blinded values it can't read and keeps nothing about the request.
type Issuer struct {
	dir string
	// KeyBits is the size of new signing keys. Zero means 2048, which gives
	// RFC 9578's 256-byte authenticator.
	KeyBits int
	// Random defaults to crypto/rand.
	Random io.Reader

	mu   sync.Mutex
	keys map[string]*monthKey
}

type monthKey struct {
	month string
	sk    *rsa.PrivateKey
	id    [keyIDLen]byte
}

// PublicKey is one key phones may blind against or verify with.
type PublicKey struct {
	ID        [keyIDLen]byte
	Key       *rsa.PublicKey
	NotBefore time.Time // start of its signing month
	NotAfter  time.Time // its tokens are refused from here on
}

func Open(dir string) (*Issuer, error) {
	for _, d := range []string{"keys", "spent"} {
		if err := os.MkdirAll(filepath.Join(dir, d), 0o700); err != nil {
			return nil, err
		}
	}
	return &Issuer{dir: dir, keys: map[string]*monthKey{}}, nil
}

func monthStart(t time.Time) time.Time {
	t = t.UTC()
	return time.Date(t.Year(), t.Month(), 1, 0, 0, 0, 0, time.UTC)
}

func monthName(t time.Time) string { return monthStart(t).Format("2006-01") }

func (i *Issuer) random() io.Reader {
	if i.Random != nil {
		return i.Random
	}
	return rand.Reader
}

func (i *Issuer) keyPath(month string) string {
	return filepath.Join(i.dir, "keys", month+".pem")
}

// key returns a month's key, loading it from disk, or creating it when
// create is set and none exists. A key file that can't be read is an error,
// never replaced: replacing it would void every token already issued.
func (i *Issuer) key(month string, create bool) (*monthKey, error) {
	i.mu.Lock()
	defer i.mu.Unlock()
	if k := i.keys[month]; k != nil {
		return k, nil
	}
	data, err := os.ReadFile(i.keyPath(month))
	if errors.Is(err, os.ErrNotExist) {
		if !create {
			return nil, ErrUnknownKey
		}
		if data, err = i.createKey(month); err != nil {
			return nil, err
		}
	} else if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, fmt.Errorf("tokens: key %s is not PEM", month)
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("tokens: key %s: %w", month, err)
	}
	sk, ok := parsed.(*rsa.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("tokens: key %s is not RSA", month)
	}
	id, err := KeyID(&sk.PublicKey)
	if err != nil {
		return nil, err
	}
	k := &monthKey{month: month, sk: sk, id: id}
	i.keys[month] = k
	return k, nil
}

// createKey writes a new key for month and returns the file's content. It
// links the file into place, so a second server process racing to create
// the same month's key gets the first one's key, not its own.
func (i *Issuer) createKey(month string) ([]byte, error) {
	bits := i.KeyBits
	if bits == 0 {
		bits = 2048
	}
	sk, err := rsa.GenerateKey(i.random(), bits)
	if err != nil {
		return nil, err
	}
	der, err := x509.MarshalPKCS8PrivateKey(sk)
	if err != nil {
		return nil, err
	}
	data := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	tmp, err := os.CreateTemp(filepath.Join(i.dir, "keys"), ".tmp-*")
	if err != nil {
		return nil, err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return nil, err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return nil, err
	}
	if err := tmp.Close(); err != nil {
		return nil, err
	}
	if err := os.Link(tmp.Name(), i.keyPath(month)); errors.Is(err, os.ErrExist) {
		return os.ReadFile(i.keyPath(month))
	} else if err != nil {
		return nil, err
	}
	return data, nil
}

// SPKI is the key's PKIX DER, the bytes its ID hashes.
func (k PublicKey) SPKI() ([]byte, error) { return x509.MarshalPKIXPublicKey(k.Key) }

func (k *monthKey) public() PublicKey {
	start, _ := time.Parse("2006-01", k.month)
	return PublicKey{ID: k.id, Key: &k.sk.PublicKey, NotBefore: start, NotAfter: start.AddDate(0, 2, 0)}
}

// PublicKeys lists the keys in use at now, newest first: this month's
// (created if needed), and last month's if it exists. Every caller gets the
// same list, so a phone can check it wasn't handed a key of its own.
func (i *Issuer) PublicKeys(now time.Time) ([]PublicKey, error) {
	cur, err := i.key(monthName(now), true)
	if err != nil {
		return nil, err
	}
	out := []PublicKey{cur.public()}
	if prev, err := i.key(monthName(monthStart(now).AddDate(0, -1, 0)), false); err == nil {
		out = append(out, prev.public())
	} else if !errors.Is(err, ErrUnknownKey) {
		return nil, err
	}
	return out, nil
}

// Sign blind-signs each message with this month's key. keyID is the key the
// phone blinded against; if it isn't this month's, the phone must fetch the
// keys again, since a signature from another key wouldn't unblind.
func (i *Issuer) Sign(now time.Time, keyID [keyIDLen]byte, blinded [][]byte) ([][]byte, error) {
	if len(blinded) == 0 || len(blinded) > MaxPerRequest {
		return nil, ErrTooMany
	}
	k, err := i.key(monthName(now), true)
	if err != nil {
		return nil, err
	}
	if !equal(keyID[:], k.id[:]) {
		return nil, ErrStaleKey
	}
	// Check every message before signing any, so a bad one costs nothing.
	size := modulusLen(&k.sk.PublicKey)
	for _, b := range blinded {
		if len(b) != size {
			return nil, ErrInvalidInput
		}
	}
	out := make([][]byte, len(blinded))
	for n, b := range blinded {
		if out[n], err = BlindSign(i.random(), k.sk, b); err != nil {
			return nil, err
		}
	}
	return out, nil
}

// Redeem accepts a token made for purpose exactly once. It checks the key,
// the purpose and the signature before recording the spend, and the record
// is created exclusively on disk, so two requests racing with one token,
// or a restart, can't spend it twice.
func (i *Issuer) Redeem(now time.Time, raw []byte, purpose string) error {
	t, err := ParseToken(raw)
	if err != nil {
		return err
	}
	var k *monthKey
	for _, m := range []string{monthName(now), monthName(monthStart(now).AddDate(0, -1, 0))} {
		cand, err := i.key(m, false)
		if errors.Is(err, ErrUnknownKey) {
			continue
		} else if err != nil {
			return err
		}
		if equal(cand.id[:], t.KeyID[:]) {
			k = cand
			break
		}
	}
	if k == nil {
		return ErrUnknownKey
	}
	want := ChallengeDigest(purpose)
	if !equal(want[:], t.ChallengeDigest[:]) {
		return ErrWrongPurpose
	}
	if len(t.Authenticator) != modulusLen(&k.sk.PublicKey) {
		return ErrMalformed
	}
	if err := Verify(&k.sk.PublicKey, t.Input(), t.Authenticator); err != nil {
		return err
	}
	dir := filepath.Join(i.dir, "spent", k.month)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	f, err := os.OpenFile(filepath.Join(dir, hex.EncodeToString(t.Nonce[:])), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if errors.Is(err, os.ErrExist) {
		return ErrSpent
	} else if err != nil {
		return err
	}
	return f.Close()
}

// Prune deletes keys and spent records older than last month: their tokens
// are refused anyway. It returns how many months it removed.
func (i *Issuer) Prune(now time.Time) (int, error) {
	oldest := monthName(monthStart(now).AddDate(0, -1, 0))
	months := map[string]bool{}
	keys, err := os.ReadDir(filepath.Join(i.dir, "keys"))
	if err != nil {
		return 0, err
	}
	for _, e := range keys {
		if m, ok := strings.CutSuffix(e.Name(), ".pem"); ok && m < oldest {
			months[m] = true
		}
	}
	spent, err := os.ReadDir(filepath.Join(i.dir, "spent"))
	if err != nil {
		return 0, err
	}
	for _, e := range spent {
		if e.IsDir() && e.Name() < oldest {
			months[e.Name()] = true
		}
	}
	sorted := make([]string, 0, len(months))
	for m := range months {
		sorted = append(sorted, m)
	}
	sort.Strings(sorted)
	for _, m := range sorted {
		i.mu.Lock()
		delete(i.keys, m)
		i.mu.Unlock()
		if err := os.Remove(i.keyPath(m)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return 0, err
		}
		if err := os.RemoveAll(filepath.Join(i.dir, "spent", m)); err != nil {
			return 0, err
		}
	}
	return len(sorted), nil
}

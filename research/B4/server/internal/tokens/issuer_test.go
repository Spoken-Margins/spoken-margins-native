package tokens

import (
	"bytes"
	"crypto/rand"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

var october = time.Date(2026, 10, 3, 18, 0, 0, 0, time.UTC)

// Small keys keep the tests quick; one test uses the production size.
func openIssuer(t *testing.T, dir string) *Issuer {
	t.Helper()
	i, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	i.KeyBits = 1024
	return i
}

// issue runs the phone's side and the server's side for one token.
func issue(t *testing.T, i *Issuer, now time.Time, purpose string) []byte {
	t.Helper()
	keys, err := i.PublicKeys(now)
	if err != nil {
		t.Fatal(err)
	}
	p, err := NewPending(rand.Reader, keys[0].Key, purpose)
	if err != nil {
		t.Fatal(err)
	}
	sigs, err := i.Sign(now, keys[0].ID, [][]byte{p.Blinded})
	if err != nil {
		t.Fatal(err)
	}
	tok, err := p.Finish(sigs[0])
	if err != nil {
		t.Fatal(err)
	}
	return tok
}

func TestIssueAndRedeemOnceAtProductionSize(t *testing.T) {
	dir := t.TempDir()
	i, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	tok := issue(t, i, october, "maps")
	if len(tok) != 2+32+32+32+256 {
		t.Fatalf("token is %d bytes, want RFC 9578's 354 for a 2048-bit key", len(tok))
	}
	if err := i.Redeem(october, tok, "maps"); err != nil {
		t.Fatal(err)
	}
	if err := i.Redeem(october, tok, "maps"); !errors.Is(err, ErrSpent) {
		t.Fatalf("second spend: got %v, want ErrSpent", err)
	}
	// A restart doesn't make it spendable again, and keeps the key.
	again, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := again.Redeem(october, tok, "maps"); !errors.Is(err, ErrSpent) {
		t.Fatalf("spend after restart: got %v, want ErrSpent", err)
	}
	info, err := os.Stat(filepath.Join(dir, "keys", "2026-10.pem"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("key file mode %v, want 0600", info.Mode().Perm())
	}
}

func TestRedeemRefusesAlteredTokens(t *testing.T) {
	i := openIssuer(t, t.TempDir())
	tok := issue(t, i, october, "maps")
	cases := []struct {
		name   string
		offset int
		want   error
	}{
		{"token type", 1, ErrMalformed},
		{"nonce", 2, ErrInvalidSignature},
		{"challenge digest", 2 + 32, ErrWrongPurpose},
		{"key id", 2 + 64, ErrUnknownKey},
		{"authenticator", len(tok) - 1, ErrInvalidSignature},
	}
	for _, c := range cases {
		bad := append([]byte(nil), tok...)
		bad[c.offset] ^= 0x01
		if err := i.Redeem(october, bad, "maps"); !errors.Is(err, c.want) {
			t.Errorf("flipped %s: got %v, want %v", c.name, err, c.want)
		}
	}
	if err := i.Redeem(october, tok[:len(tok)-1], "maps"); !errors.Is(err, ErrMalformed) {
		t.Errorf("short authenticator: got %v", err)
	}
	if err := i.Redeem(october, tok, "voices"); !errors.Is(err, ErrWrongPurpose) {
		t.Errorf("other purpose: got %v", err)
	}
	other := openIssuer(t, t.TempDir())
	if err := i.Redeem(october, issue(t, other, october, "maps"), "maps"); !errors.Is(err, ErrUnknownKey) {
		t.Errorf("another server's token: got %v", err)
	}
	// None of the refusals spent the real token.
	if err := i.Redeem(october, tok, "maps"); err != nil {
		t.Fatalf("the untouched token: %v", err)
	}
}

func TestSignRefusals(t *testing.T) {
	i := openIssuer(t, t.TempDir())
	keys, err := i.PublicKeys(october)
	if err != nil {
		t.Fatal(err)
	}
	p, err := NewPending(rand.Reader, keys[0].Key, "maps")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := i.Sign(october, [32]byte{1}, [][]byte{p.Blinded}); !errors.Is(err, ErrStaleKey) {
		t.Errorf("other key id: got %v", err)
	}
	eleven := make([][]byte, MaxPerRequest+1)
	for n := range eleven {
		eleven[n] = p.Blinded
	}
	if _, err := i.Sign(october, keys[0].ID, eleven); !errors.Is(err, ErrTooMany) {
		t.Errorf("eleven messages: got %v", err)
	}
	if _, err := i.Sign(october, keys[0].ID, nil); !errors.Is(err, ErrTooMany) {
		t.Errorf("no messages: got %v", err)
	}
	if _, err := i.Sign(october, keys[0].ID, [][]byte{p.Blinded, p.Blinded[1:]}); !errors.Is(err, ErrInvalidInput) {
		t.Errorf("one short message: got %v", err)
	}
	// One value above the modulus refuses the batch before any signing.
	big := bytes.Repeat([]byte{0xff}, len(p.Blinded))
	counting := &countingReader{r: rand.Reader}
	i.Random = counting
	if _, err := i.Sign(october, keys[0].ID, [][]byte{p.Blinded, big}); !errors.Is(err, ErrInvalidInput) {
		t.Errorf("one value above the modulus: got %v", err)
	}
	if counting.n != 0 {
		t.Errorf("signed %d bytes' worth before refusing the batch", counting.n)
	}
}

func TestMonthlyKeysRollOverAndExpire(t *testing.T) {
	dir := t.TempDir()
	i := openIssuer(t, dir)
	octTok := issue(t, i, october, "maps")
	spentOct := issue(t, i, october, "maps")
	if err := i.Redeem(october, spentOct, "maps"); err != nil {
		t.Fatal(err)
	}

	november := october.AddDate(0, 1, 0)
	keys, err := i.PublicKeys(november)
	if err != nil {
		t.Fatal(err)
	}
	if len(keys) != 2 || keys[0].NotBefore.Month() != time.November || keys[1].NotBefore.Month() != time.October {
		t.Fatalf("november keys: %+v", keys)
	}
	if keys[1].NotAfter != time.Date(2026, 12, 1, 0, 0, 0, 0, time.UTC) {
		t.Fatalf("october key expires %v", keys[1].NotAfter)
	}
	// October's token still spends in November; signing uses November's key.
	if err := i.Redeem(november, octTok, "maps"); err != nil {
		t.Fatalf("october token in november: %v", err)
	}
	octID := keys[1].ID
	p, _ := NewPending(rand.Reader, keys[1].Key, "maps")
	if _, err := i.Sign(november, octID, [][]byte{p.Blinded}); !errors.Is(err, ErrStaleKey) {
		t.Fatalf("signing with last month's key: %v", err)
	}

	// In December an October token is refused, and pruning removes October.
	decTok := issue(t, i, october, "maps")
	december := october.AddDate(0, 2, 0)
	if err := i.Redeem(december, decTok, "maps"); !errors.Is(err, ErrUnknownKey) {
		t.Fatalf("october token in december: %v", err)
	}
	n, err := i.Prune(december)
	if err != nil || n != 1 {
		t.Fatalf("prune: %d, %v", n, err)
	}
	for _, p := range []string{"keys/2026-10.pem", "spent/2026-10"} {
		if _, err := os.Stat(filepath.Join(dir, p)); !errors.Is(err, os.ErrNotExist) {
			t.Errorf("%s survived the prune: %v", p, err)
		}
	}
	if _, err := os.Stat(filepath.Join(dir, "keys", "2026-11.pem")); err != nil {
		t.Errorf("november's key was pruned: %v", err)
	}
}

func TestRestartKeepsTheKey(t *testing.T) {
	dir := t.TempDir()
	a, err := openIssuer(t, dir).PublicKeys(october)
	if err != nil {
		t.Fatal(err)
	}
	b, err := openIssuer(t, dir).PublicKeys(october)
	if err != nil {
		t.Fatal(err)
	}
	if a[0].ID != b[0].ID {
		t.Fatal("a restart made a new key for the same month")
	}
}

func TestDamagedKeyIsNeverReplaced(t *testing.T) {
	dir := t.TempDir()
	i := openIssuer(t, dir)
	path := filepath.Join(dir, "keys", "2026-10.pem")
	if err := os.WriteFile(path, []byte("not a key"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := i.PublicKeys(october); err == nil {
		t.Fatal("a damaged key was accepted")
	}
	if data, _ := os.ReadFile(path); string(data) != "not a key" {
		t.Fatal("the damaged key file was overwritten")
	}
}

// Two requests racing with the same token: exactly one spends it.
func TestConcurrentRedeemSpendsOnce(t *testing.T) {
	i := openIssuer(t, t.TempDir())
	tok := issue(t, i, october, "maps")
	var wg sync.WaitGroup
	results := make(chan error, 20)
	for n := 0; n < 20; n++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			results <- i.Redeem(october, tok, "maps")
		}()
	}
	wg.Wait()
	close(results)
	ok := 0
	for err := range results {
		switch {
		case err == nil:
			ok++
		case !errors.Is(err, ErrSpent):
			t.Errorf("unexpected: %v", err)
		}
	}
	if ok != 1 {
		t.Fatalf("%d redemptions succeeded, want 1", ok)
	}
}

// countingReader counts the randomness signing draws, to show none was used.
type countingReader struct {
	r io.Reader
	n int
}

func (c *countingReader) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	c.n += n
	return n, err
}

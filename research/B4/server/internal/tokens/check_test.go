package tokens

import (
	"errors"
	"testing"
)

// Check answers what Redeem would without spending, so a caller can look
// at a token, decide it has no work to pay for, and leave it spendable.
func TestCheckDoesNotSpend(t *testing.T) {
	i := openIssuer(t, t.TempDir())
	tok := issue(t, i, october, "maps")
	for n := 0; n < 2; n++ {
		if err := i.Check(october, tok, "maps"); err != nil {
			t.Fatalf("check %d: %v", n+1, err)
		}
	}
	if err := i.Redeem(october, tok, "maps"); err != nil {
		t.Fatalf("redeem after checks: %v", err)
	}
	if err := i.Check(october, tok, "maps"); !errors.Is(err, ErrSpent) {
		t.Fatalf("check after spend: got %v, want ErrSpent", err)
	}

	forged := issue(t, i, october, "maps")
	forged[len(forged)-1] ^= 1
	other := issue(t, openIssuer(t, t.TempDir()), october, "maps")
	for name, c := range map[string]struct {
		tok     []byte
		purpose string
	}{
		"forged":        {forged, "maps"},
		"other purpose": {issue(t, i, october, "bridge"), "maps"},
		"other server":  {other, "maps"},
		"truncated":     {tok[:40], "maps"},
	} {
		err := i.Check(october, c.tok, c.purpose)
		if err == nil || !Refused(err) {
			t.Errorf("%s: got %v, want a refusal", name, err)
		}
	}
	if Refused(errors.New("disk full")) {
		t.Error("a server fault counted as a refused token")
	}
}

// The challenge a server sends is the one whose digest the token carries.
func TestChallengeMatchesItsDigest(t *testing.T) {
	c := Challenge("maps")
	if len(c) != 2+2+len(IssuerName)+1+2+len("maps") {
		t.Fatalf("challenge is %d bytes", len(c))
	}
	tok := issue(t, openIssuer(t, t.TempDir()), october, "maps")
	parsed, err := ParseToken(tok)
	if err != nil {
		t.Fatal(err)
	}
	if parsed.ChallengeDigest != ChallengeDigest("maps") {
		t.Fatal("token's challenge digest isn't ChallengeDigest(maps)")
	}
}

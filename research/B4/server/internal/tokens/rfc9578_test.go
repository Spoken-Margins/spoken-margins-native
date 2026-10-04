package tokens

import (
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"os"
	"testing"
)

// RFC 9578 Appendix A.2's five type 2 vectors, copied verbatim into
// testdata/rfc9578-type2-vectors.json. They check what other Privacy Pass
// code (and the app) will compute: the key encoding and key id, the token
// layout, the blinded request and the final token.
func TestRFC9578Type2Vectors(t *testing.T) {
	data, err := os.ReadFile("testdata/rfc9578-type2-vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	var vectors []map[string]string
	if err := json.Unmarshal(data, &vectors); err != nil {
		t.Fatal(err)
	}
	if len(vectors) != 5 {
		t.Fatalf("%d vectors, want 5", len(vectors))
	}
	for n, v := range vectors {
		field := func(k string) []byte {
			b, err := hex.DecodeString(v[k])
			if err != nil || len(b) == 0 {
				t.Fatalf("vector %d field %s: %v", n, k, err)
			}
			return b
		}
		block, _ := pem.Decode(field("skI"))
		if block == nil {
			t.Fatalf("vector %d: skI is not PEM", n)
		}
		parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
		if err != nil {
			t.Fatal(err)
		}
		sk := parsed.(*rsa.PrivateKey)
		pk := &sk.PublicKey

		spki, err := SPKI(pk)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(spki, field("pkI")) {
			t.Fatalf("vector %d: SPKI differs from pkI", n)
		}
		parsedPK, err := ParseSPKI(field("pkI"))
		if err != nil || parsedPK.N.Cmp(pk.N) != 0 {
			t.Fatalf("vector %d: ParseSPKI: %v", n, err)
		}
		id, _ := KeyID(pk)
		if id != sha256.Sum256(field("pkI")) {
			t.Fatalf("vector %d: key id is not SHA-256(pkI)", n)
		}

		raw := field("token")
		tok, err := ParseToken(raw)
		if err != nil {
			t.Fatal(err)
		}
		if tok.KeyID != id || tok.ChallengeDigest != sha256.Sum256(field("token_challenge")) {
			t.Fatalf("vector %d: token fields don't match the key and challenge", n)
		}
		if !bytes.Equal(tok.Marshal(), raw) {
			t.Fatalf("vector %d: token doesn't round-trip", n)
		}

		// token_request = token_type, truncated key id, blinded message.
		req := field("token_request")
		if req[2] != id[len(id)-1] {
			t.Fatalf("vector %d: truncated key id", n)
		}
		r := new(big.Int).SetBytes(field("blind"))
		inv := new(big.Int).ModInverse(r, pk.N)
		blinded, err := blindWith(pk, tok.Input(), field("salt"), r)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(blinded, req[3:]) {
			t.Fatalf("vector %d: blinded message differs from token_request", n)
		}
		resp, err := BlindSign(rand.Reader, sk, blinded)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(resp, field("token_response")) {
			t.Fatalf("vector %d: blind signature differs from token_response", n)
		}
		sig, err := Finalize(pk, tok.Input(), resp, inv)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(sig, tok.Authenticator) {
			t.Fatalf("vector %d: final signature differs from the token's", n)
		}
	}
}

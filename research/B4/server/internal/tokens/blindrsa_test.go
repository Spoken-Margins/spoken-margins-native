package tokens

import (
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math/big"
	"os"
	"testing"
)

// rfcVector is one of RFC 9474 Appendix A's test vectors, copied verbatim
// into testdata/rfc9474-vectors.json.
type rfcVector map[string]string

func loadVector(t *testing.T, name string) (rfcVector, *rsa.PrivateKey) {
	t.Helper()
	data, err := os.ReadFile("testdata/rfc9474-vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	var all map[string]rfcVector
	if err := json.Unmarshal(data, &all); err != nil {
		t.Fatal(err)
	}
	v, ok := all[name]
	if !ok {
		t.Fatalf("no vector %s", name)
	}
	n, p, q := v.int(t, "n"), v.int(t, "p"), v.int(t, "q")
	sk := &rsa.PrivateKey{
		PublicKey: rsa.PublicKey{N: n, E: int(v.int(t, "e").Int64())},
		D:         v.int(t, "d"),
		Primes:    []*big.Int{p, q},
	}
	if err := sk.Validate(); err != nil {
		t.Fatal(err)
	}
	return v, sk
}

func (v rfcVector) bytes(t *testing.T, k string) []byte {
	t.Helper()
	b, err := hex.DecodeString(v[k])
	if err != nil || v[k] == "" {
		t.Fatalf("vector field %s: %v", k, err)
	}
	return b
}

func (v rfcVector) int(t *testing.T, k string) *big.Int {
	return new(big.Int).SetBytes(v.bytes(t, k))
}

// The whole protocol reproduces the RFC's bytes: the PSS encoding, the
// blinded message, the server's blind signature and the final signature.
func TestRFC9474Vectors(t *testing.T) {
	for _, name := range []string{"RSABSSA-SHA384-PSS-Deterministic", "RSABSSA-SHA384-PSS-Randomized"} {
		t.Run(name, func(t *testing.T) {
			v, sk := loadVector(t, name)
			pk := &sk.PublicKey
			prepared := v.bytes(t, "prepared_msg")
			if prefix, ok := v["msg_prefix"]; ok {
				want := append(v.bytes(t, "msg_prefix"), v.bytes(t, "msg")...)
				if !bytes.Equal(prepared, want) || len(prefix) != 64 {
					t.Fatal("randomized prepare is not prefix || msg")
				}
			} else if !bytes.Equal(prepared, v.bytes(t, "msg")) {
				t.Fatal("deterministic prepare changed the message")
			}

			em, err := encodePSS(prepared, pk.N.BitLen()-1, v.bytes(t, "salt"))
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(em, v.bytes(t, "encoded_msg")) {
				t.Fatal("encoded_msg differs from the RFC")
			}

			inv := v.int(t, "inv")
			r := new(big.Int).ModInverse(inv, pk.N)
			blinded, err := blindWith(pk, prepared, v.bytes(t, "salt"), r)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(blinded, v.bytes(t, "blinded_msg")) {
				t.Fatal("blinded_msg differs from the RFC")
			}

			blindSig, err := BlindSign(rand.Reader, sk, blinded)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(blindSig, v.bytes(t, "blind_sig")) {
				t.Fatal("blind_sig differs from the RFC")
			}

			sig, err := Finalize(pk, prepared, blindSig, inv)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(sig, v.bytes(t, "sig")) {
				t.Fatal("sig differs from the RFC")
			}
			if err := Verify(pk, prepared, sig); err != nil {
				t.Fatal(err)
			}
			if err := Verify(pk, append([]byte{0}, prepared...), sig); err == nil {
				t.Fatal("a signature verified for a different message")
			}
		})
	}
}

// A random round trip with the exported client functions.
func TestBlindRoundTrip(t *testing.T) {
	_, sk := loadVector(t, "RSABSSA-SHA384-PSS-Deterministic")
	msg := []byte("spoken margins")
	blinded, inv, err := Blind(rand.Reader, &sk.PublicKey, msg)
	if err != nil {
		t.Fatal(err)
	}
	blindSig, err := BlindSign(rand.Reader, sk, blinded)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Finalize(&sk.PublicKey, msg, blindSig, inv); err != nil {
		t.Fatal(err)
	}
	if _, err := Finalize(&sk.PublicKey, []byte("something else"), blindSig, inv); !errors.Is(err, ErrInvalidSignature) {
		t.Fatalf("finalize for another message: %v", err)
	}
}

// A damaged private key makes signing fail instead of returning a signature
// that doesn't verify (RFC 9474 §4.3 steps 3 and 4).
func TestBlindSignChecksItsOwnOutput(t *testing.T) {
	v, sk := loadVector(t, "RSABSSA-SHA384-PSS-Deterministic")
	bad := *sk
	bad.D = new(big.Int).Add(sk.D, big.NewInt(2))
	if _, err := BlindSign(rand.Reader, &bad, v.bytes(t, "blinded_msg")); !errors.Is(err, ErrSigningFailure) {
		t.Fatalf("damaged key: got %v, want ErrSigningFailure", err)
	}
}

func TestBlindSignRejectsOutOfRangeInput(t *testing.T) {
	_, sk := loadVector(t, "RSABSSA-SHA384-PSS-Deterministic")
	size := modulusLen(&sk.PublicKey)
	cases := map[string][]byte{
		"short":          make([]byte, size-1),
		"long":           make([]byte, size+1),
		"modulus itself": intToBytes(sk.N, size),
		"all ones":       bytes.Repeat([]byte{0xff}, size),
	}
	for name, b := range cases {
		if _, err := BlindSign(rand.Reader, sk, b); !errors.Is(err, ErrInvalidInput) {
			t.Errorf("%s: got %v, want ErrInvalidInput", name, err)
		}
	}
}

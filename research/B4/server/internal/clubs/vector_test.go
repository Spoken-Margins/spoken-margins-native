package clubs

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hkdf"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"spokenmargins.dev/bridge/internal/links"
)

// The phone's club sealing (Packages/SessionKit ClubSealing, #1799) and this server agree on one vector,
// research/B4/contracts/fixtures/club-sealing-vector.json, made with Python's cryptography library. The Swift tests
// check the same file. This side proves the server's rules accept what the phone sends and that the phone's derived
// values are exactly what the server stores and compares.
type sealedEntry struct {
	Part      byte   `json:"part"`
	NonceHex  string `json:"nonceHex"`
	AADHex    string `json:"aadHex"`
	Plaintext string `json:"plaintextBase64"`
	Sealed    string `json:"sealedBase64"`
}

type clubVector struct {
	KeyFragment string        `json:"keyFragment"`
	InviteURL   string        `json:"inviteURL"`
	ID          string        `json:"id"`
	ReadProof   string        `json:"readProof"`
	PostProof   string        `json:"postProof"`
	ReadHash    string        `json:"readHash"`
	PostHash    string        `json:"postHash"`
	SealKeyHex  string        `json:"sealKeyHex"`
	Header      sealedEntry   `json:"header"`
	Posts       []sealedEntry `json:"posts"`
}

func loadClubVector(t *testing.T) clubVector {
	t.Helper()
	data, err := os.ReadFile("../../../contracts/fixtures/club-sealing-vector.json")
	if err != nil {
		t.Fatal(err)
	}
	var v clubVector
	if err := json.Unmarshal(data, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

func b64(t *testing.T, s string) []byte {
	t.Helper()
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil || len(b) == 0 {
		t.Fatalf("vector base64: %v", err)
	}
	return b
}

func unhex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestTheVectorsDerivedValuesAreWhatTheServerStoresAndCompares(t *testing.T) {
	v := loadClubVector(t)
	secret, err := base64.RawURLEncoding.DecodeString(v.KeyFragment)
	if err != nil || len(secret) != 32 {
		t.Fatalf("key: %v", err)
	}
	derive := func(info string, n int) []byte {
		b, err := hkdf.Key(sha256.New, secret, nil, info, n)
		if err != nil {
			t.Fatal(err)
		}
		return b
	}
	if got := hex.EncodeToString(derive("sm-club-id-v1", 16)); got != v.ID {
		t.Fatalf("id: %s, vector %s", got, v.ID)
	}
	if got := hex.EncodeToString(derive("sm-club-read-v1", 32)); got != v.ReadProof {
		t.Fatalf("read proof: %s", got)
	}
	if got := hex.EncodeToString(derive("sm-club-post-v1", 32)); got != v.PostProof {
		t.Fatalf("post proof: %s", got)
	}
	if got := hex.EncodeToString(derive("sm-club-seal-v1", 32)); got != v.SealKeyHex {
		t.Fatalf("seal key: %s", got)
	}
	if !strings.HasSuffix(strings.SplitN(v.InviteURL, "#", 2)[0], "/c/"+v.ID) || !strings.HasSuffix(v.InviteURL, "#"+v.KeyFragment) {
		t.Fatalf("invite link: %s", v.InviteURL)
	}
	if !ValidID(v.ID) || !ValidHash(v.ReadHash) || !ValidHash(v.PostHash) {
		t.Fatal("the phone's id or hashes are not what the server accepts")
	}
	for proof, want := range map[string]string{v.ReadProof: v.ReadHash, v.PostProof: v.PostHash} {
		if got, ok := HashProof(proof); !ok || got != want {
			t.Fatalf("HashProof(%s…) = %s, want %s", proof[:6], got, want)
		}
	}
	// None of the four is a prefix or a copy of another, and the secret itself is in none of them.
	all := []string{v.ID, v.ReadProof, v.PostProof, v.SealKeyHex, hex.EncodeToString(secret)}
	for i := range all {
		for j := range all {
			if i != j && strings.Contains(all[i], all[j]) {
				t.Fatalf("value %d contains value %d", i, j)
			}
		}
	}
}

func TestTheVectorsSealedItemsAreWhatTheServerAcceptsAndTheKeyOpens(t *testing.T) {
	v := loadClubVector(t)
	header := b64(t, v.Header.Sealed)
	if !links.Sealed(header, links.PartClubHeader) || links.Sealed(header, links.PartPacket) {
		t.Fatal("the server does not take the phone's header as a club header")
	}
	for _, p := range v.Posts {
		if !links.Sealed(b64(t, p.Sealed), links.PartPacket) {
			t.Fatal("the server does not take the phone's post as a packet")
		}
	}

	// Open each with the seal key and the additional data the design names: header || club id.
	block, err := aes.NewCipher(unhex(t, v.SealKeyHex))
	if err != nil {
		t.Fatal(err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range append([]sealedEntry{v.Header}, v.Posts...) {
		sealed := b64(t, e.Sealed)
		aad := append(append([]byte{}, sealed[:8]...), unhex(t, v.ID)...)
		if hex.EncodeToString(aad) != e.AADHex {
			t.Fatalf("aad %x, vector %s", aad, e.AADHex)
		}
		nonce := sealed[8 : 8+gcm.NonceSize()]
		got, err := gcm.Open(nil, nonce, sealed[8+gcm.NonceSize():], aad)
		if err != nil {
			t.Fatalf("part %d does not open: %v", e.Part, err)
		}
		if !bytes.Equal(got, b64(t, e.Plaintext)) {
			t.Fatalf("part %d opened to other bytes", e.Part)
		}
		// Another club's id, or none, does not open it.
		other := append(append([]byte{}, sealed[:8]...), make([]byte, 16)...)
		if _, err := gcm.Open(nil, nonce, sealed[8+gcm.NonceSize():], other); err == nil {
			t.Fatalf("part %d opened under another club id", e.Part)
		}
	}
}

func TestAClubTheVectorMakesWorksThroughTheStore(t *testing.T) {
	v := loadClubVector(t)
	s := open(t)
	if ok, err := s.Create(v.ID, v.ReadHash, v.PostHash, b64(t, v.Header.Sealed), t0); err != nil || !ok {
		t.Fatalf("create: %v %v", ok, err)
	}
	for i, p := range v.Posts {
		seq, err := s.Post(v.ID, v.PostProof, b64(t, p.Sealed), t0)
		if err != nil || seq != i+1 {
			t.Fatalf("post %d: %d %v", i, seq, err)
		}
	}
	c := club{id: v.ID, read: v.ReadProof, post: v.PostProof}
	if !bytes.Equal(item(t, s, c, 0), b64(t, v.Header.Sealed)) {
		t.Fatal("header changed in the box")
	}
	for i, p := range v.Posts {
		if !bytes.Equal(item(t, s, c, i+1), b64(t, p.Sealed)) {
			t.Fatalf("post %d changed in the box", i+1)
		}
	}
	// The read proof does not post and the post proof does not read.
	if _, err := s.Post(v.ID, v.ReadProof, b64(t, v.Posts[0].Sealed), t0); err == nil {
		t.Fatal("the read proof posted")
	}
	if _, err := s.List(v.ID, v.PostProof, 0, t0); err == nil {
		t.Fatal("the post proof read")
	}
}

package links

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// A link's sealed reply part (#4675, docs/design/reply-mailbox.md): stored as it came, served while the link
// is, and deleted with the link's other content.
func replyVectorPart(t *testing.T) []byte {
	t.Helper()
	data, err := os.ReadFile("../../../contracts/fixtures/reply-box-vector.json")
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		ReplyPart struct {
			SealedBase64 string `json:"sealedBase64"`
		} `json:"replyPart"`
	}
	if err := json.Unmarshal(data, &v); err != nil {
		t.Fatal(err)
	}
	part, err := base64.StdEncoding.DecodeString(v.ReplyPart.SealedBase64)
	if err != nil {
		t.Fatal(err)
	}
	return part
}

func TestAReplyPartIsStoredOnceServedAndGoesWithItsLink(t *testing.T) {
	preview, packet, _, _ := loadVector(t)
	part := replyVectorPart(t)
	if !Sealed(part, PartReply) || PartReply != 4 {
		t.Fatal("the vector's reply part is not sealed part 4")
	}
	now := time.Date(2026, 11, 26, 9, 0, 0, 0, time.UTC)
	s, err := OpenStore(filepath.Join(t.TempDir(), "links"))
	if err != nil {
		t.Fatal(err)
	}
	id, _, err := s.Put(packet, preview, now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Reply(id, now); !errors.Is(err, ErrNotFound) {
		t.Fatalf("a link with no part: %v, want ErrNotFound", err)
	}
	wrong := append([]byte{}, part...)
	wrong[7] = PartPacket
	if err := s.PutReply(id, wrong, now); !errors.Is(err, ErrUnsealed) {
		t.Fatalf("a packet as the part: %v", err)
	}
	if err := s.PutReply(id, append(part[:8:8], make([]byte, MaxReplyBytes)...), now); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("over 1 KiB: %v", err)
	}
	if err := s.PutReply("ffffffffffffffffffffffffffffffff", part, now); !errors.Is(err, ErrNotFound) {
		t.Fatalf("no such link: %v", err)
	}
	if err := s.PutReply(id, part, now); err != nil {
		t.Fatal(err)
	}
	if err := s.PutReply(id, sealedReply(60), now); err == nil {
		t.Fatal("a second reply part replaced the first")
	}
	if got, err := s.Reply(id, now); err != nil || !bytes.Equal(got, part) {
		t.Fatalf("reply part changed: %v", err)
	}
	if _, err := s.Reply(id, now.Add(Lifetime)); !errors.Is(err, ErrGone) {
		t.Fatalf("after expiry: %v, want ErrGone", err)
	}
	if n, err := s.Sweep(now.Add(Lifetime)); err != nil || n != 1 {
		t.Fatalf("sweep: %d %v", n, err)
	}
	if _, err := os.Stat(filepath.Join(s.dir, id, replyFile)); !os.IsNotExist(err) {
		t.Fatal("the sweep left the reply part")
	}

	id2, _, _ := s.Put(packet, preview, now)
	if err := s.PutReply(id2, part, now); err != nil {
		t.Fatal(err)
	}
	if err := s.Takedown(id2); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(s.dir, id2, replyFile)); !os.IsNotExist(err) {
		t.Fatal("the takedown left the reply part")
	}
	if _, err := s.Reply(id2, now); !errors.Is(err, ErrGone) {
		t.Fatalf("after takedown: %v, want ErrGone", err)
	}
	if err := s.PutReply(id2, part, now); !errors.Is(err, ErrGone) {
		t.Fatalf("a part for a taken-down link: %v", err)
	}
}

func sealedReply(n int) []byte {
	return append([]byte{'S', 'M', 'L', 'I', 'N', 'K', 1, PartReply}, make([]byte, n-8)...)
}

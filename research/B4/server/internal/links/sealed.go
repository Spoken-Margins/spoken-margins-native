package links

import (
	"bytes"
	"embed"
)

// A share link's preview and packet arrive sealed on the sender's phone (#805): each part is
// header ("SMLINK", version 1, part) || nonce (12) || ciphertext || tag (16), AES-256-GCM under a
// key that travels only in the link's # part. The server can't open them and doesn't try. It checks
// only the 8-byte header and the minimum length, so a plaintext upload, or a packet sent as the
// preview, is refused instead of being stored readable. The app's ShareLinkSealing
// (Packages/SessionKit) and share-link-open.mjs define the format; both check against
// research/B4/contracts/fixtures/share-link-sealing-vector.json.
const (
	PartPreview byte = 1
	PartPacket  byte = 2

	sealedVersion  = 1
	nonceBytes     = 12
	tagBytes       = 16
	SealedOverhead = 8 + nonceBytes + tagBytes
)

var sealedMagic = []byte("SMLINK")

// Sealed reports whether data is shaped like a sealed part of the given kind.
func Sealed(data []byte, part byte) bool {
	header := append(append([]byte{}, sealedMagic...), sealedVersion, part)
	return len(data) >= SealedOverhead && bytes.HasPrefix(data, header)
}

// The browser half of the landing page: share-link-page.mjs fetches the sealed preview and opens
// it with share-link-open.mjs, using the key in location.hash.
//
//go:embed share-link-open.mjs share-link-page.mjs
var pageScripts embed.FS

// PageScript returns one of the landing page's two modules by file name.
func PageScript(name string) ([]byte, bool) {
	if name != "share-link-open.mjs" && name != "share-link-page.mjs" {
		return nil, false
	}
	data, err := pageScripts.ReadFile(name)
	return data, err == nil
}

package appattest_test

import (
	"encoding/hex"
	"encoding/pem"
	"testing"
)

func mustPEM(t *testing.T, data []byte) []byte {
	t.Helper()
	b, _ := pem.Decode(data)
	if b == nil {
		t.Fatal("no PEM block")
	}
	return b.Bytes
}

func hexString(b []byte) string { return hex.EncodeToString(b) }

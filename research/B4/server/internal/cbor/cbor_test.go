package cbor

import (
	"bytes"
	"errors"
	"reflect"
	"testing"
)

func TestRoundTrip(t *testing.T) {
	in := map[string]any{
		"fmt":     "apple-appattest",
		"attStmt": map[string]any{"x5c": []any{[]byte{1, 2}, []byte{3}}, "receipt": []byte{}},
		"n":       int64(-7),
		"big":     uint64(1 << 40),
		"flags":   []any{true, false, nil},
	}
	enc, err := Encode(in)
	if err != nil {
		t.Fatal(err)
	}
	out, err := Decode(enc)
	if err != nil {
		t.Fatal(err)
	}
	want := map[any]any{
		"fmt":     "apple-appattest",
		"attStmt": map[any]any{"x5c": []any{[]byte{1, 2}, []byte{3}}, "receipt": []byte{}},
		"n":       int64(-7),
		"big":     uint64(1 << 40),
		"flags":   []any{true, false, nil},
	}
	if !reflect.DeepEqual(out, want) {
		t.Fatalf("round trip mismatch:\n got %#v\nwant %#v", out, want)
	}
}

// RFC 8949 Appendix A vectors for the types this codec supports.
func TestKnownEncodings(t *testing.T) {
	cases := []struct {
		v   any
		hex []byte
	}{
		{uint64(0), []byte{0x00}},
		{uint64(23), []byte{0x17}},
		{uint64(24), []byte{0x18, 0x18}},
		{uint64(1000), []byte{0x19, 0x03, 0xe8}},
		{int64(-1), []byte{0x20}},
		{int64(-1000), []byte{0x39, 0x03, 0xe7}},
		{"IETF", []byte{0x64, 0x49, 0x45, 0x54, 0x46}},
		{[]byte{1, 2, 3, 4}, []byte{0x44, 1, 2, 3, 4}},
	}
	for _, c := range cases {
		got, err := Encode(c.v)
		if err != nil || !bytes.Equal(got, c.hex) {
			t.Errorf("Encode(%#v) = %x, %v; want %x", c.v, got, err, c.hex)
		}
	}
}

func TestRejectsMalformed(t *testing.T) {
	cases := map[string][]byte{
		"empty":             {},
		"truncated string":  {0x64, 'a'},
		"huge array":        {0x9b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff},
		"huge map":          {0xbb, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff},
		"indefinite length": {0x5f, 0x41, 0x01, 0xff},
		"tag":               {0xc0, 0x00},
		"trailing bytes":    {0x00, 0x00},
		"duplicate key":     {0xa2, 0x61, 'a', 0x00, 0x61, 'a', 0x01},
		"float":             {0xf9, 0x3c, 0x00},
		"array map key":     {0xa1, 0x80, 0x00},
	}
	for name, in := range cases {
		if _, err := Decode(in); !errors.Is(err, ErrMalformed) {
			t.Errorf("%s: want ErrMalformed, got %v", name, err)
		}
	}
	deep := bytes.Repeat([]byte{0x81}, maxDepth+2)
	deep = append(deep, 0x00)
	if _, err := Decode(deep); !errors.Is(err, ErrMalformed) {
		t.Errorf("deep nesting: want ErrMalformed, got %v", err)
	}
}

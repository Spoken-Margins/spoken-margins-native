// Package cbor is a minimal CBOR (RFC 8949) codec covering what Apple App
// Attest objects use: unsigned and negative integers, byte and text strings,
// arrays, maps, and the simple values false/true/null. Only definite lengths
// are accepted. It exists so the server has no third-party dependencies.
package cbor

import (
	"encoding/binary"
	"errors"
	"fmt"
	"math"
	"sort"
)

const maxDepth = 16

var ErrMalformed = errors.New("cbor: malformed input")

// Decode parses exactly one CBOR item that must span all of data.
// Maps decode to map[any]any with keys of type string, uint64 or int64.
func Decode(data []byte) (any, error) {
	d := decoder{data: data}
	v, err := d.item(0)
	if err != nil {
		return nil, err
	}
	if d.pos != len(data) {
		return nil, fmt.Errorf("%w: %d trailing bytes", ErrMalformed, len(data)-d.pos)
	}
	return v, nil
}

type decoder struct {
	data []byte
	pos  int
}

func (d *decoder) take(n uint64) ([]byte, error) {
	if n > uint64(len(d.data)-d.pos) {
		return nil, fmt.Errorf("%w: length %d exceeds input", ErrMalformed, n)
	}
	b := d.data[d.pos : d.pos+int(n)]
	d.pos += int(n)
	return b, nil
}

func (d *decoder) head() (major byte, arg uint64, err error) {
	b, err := d.take(1)
	if err != nil {
		return 0, 0, err
	}
	major, info := b[0]>>5, b[0]&0x1f
	switch {
	case info < 24:
		return major, uint64(info), nil
	case info == 24:
		b, err = d.take(1)
		if err != nil {
			return 0, 0, err
		}
		return major, uint64(b[0]), nil
	case info == 25:
		b, err = d.take(2)
		if err != nil {
			return 0, 0, err
		}
		return major, uint64(binary.BigEndian.Uint16(b)), nil
	case info == 26:
		b, err = d.take(4)
		if err != nil {
			return 0, 0, err
		}
		return major, uint64(binary.BigEndian.Uint32(b)), nil
	case info == 27:
		b, err = d.take(8)
		if err != nil {
			return 0, 0, err
		}
		return major, binary.BigEndian.Uint64(b), nil
	default:
		return 0, 0, fmt.Errorf("%w: unsupported additional info %d", ErrMalformed, info)
	}
}

func (d *decoder) item(depth int) (any, error) {
	if depth > maxDepth {
		return nil, fmt.Errorf("%w: nesting too deep", ErrMalformed)
	}
	major, arg, err := d.head()
	if err != nil {
		return nil, err
	}
	switch major {
	case 0:
		return arg, nil
	case 1:
		if arg > math.MaxInt64 {
			return nil, fmt.Errorf("%w: negative integer out of range", ErrMalformed)
		}
		return -1 - int64(arg), nil
	case 2:
		b, err := d.take(arg)
		if err != nil {
			return nil, err
		}
		return append(make([]byte, 0, len(b)), b...), nil
	case 3:
		b, err := d.take(arg)
		if err != nil {
			return nil, err
		}
		return string(b), nil
	case 4:
		// Every element takes at least one byte, which bounds allocation.
		if arg > uint64(len(d.data)-d.pos) {
			return nil, fmt.Errorf("%w: array length exceeds input", ErrMalformed)
		}
		out := make([]any, 0, arg)
		for i := uint64(0); i < arg; i++ {
			v, err := d.item(depth + 1)
			if err != nil {
				return nil, err
			}
			out = append(out, v)
		}
		return out, nil
	case 5:
		if arg > uint64(len(d.data)-d.pos)/2 {
			return nil, fmt.Errorf("%w: map length exceeds input", ErrMalformed)
		}
		out := make(map[any]any, arg)
		for i := uint64(0); i < arg; i++ {
			k, err := d.item(depth + 1)
			if err != nil {
				return nil, err
			}
			switch k.(type) {
			case string, uint64, int64:
			default:
				return nil, fmt.Errorf("%w: unsupported map key type %T", ErrMalformed, k)
			}
			if _, dup := out[k]; dup {
				return nil, fmt.Errorf("%w: duplicate map key %v", ErrMalformed, k)
			}
			v, err := d.item(depth + 1)
			if err != nil {
				return nil, err
			}
			out[k] = v
		}
		return out, nil
	case 7:
		switch arg {
		case 20:
			return false, nil
		case 21:
			return true, nil
		case 22:
			return nil, nil
		}
		return nil, fmt.Errorf("%w: unsupported simple value %d", ErrMalformed, arg)
	default:
		return nil, fmt.Errorf("%w: unsupported major type %d (tags are not accepted)", ErrMalformed, major)
	}
}

// Pair is one map entry for Encode. Map preserves the caller's key order.
type Pair struct {
	Key   any
	Value any
}

// Map encodes as a CBOR map in the given order.
type Map []Pair

// Encode serializes v. It supports the same types Decode produces, plus int,
// uint32, Map, and map[string]any (keys sorted for determinism).
func Encode(v any) ([]byte, error) {
	var out []byte
	err := encode(&out, v)
	return out, err
}

func putHead(out *[]byte, major byte, arg uint64) {
	m := major << 5
	switch {
	case arg < 24:
		*out = append(*out, m|byte(arg))
	case arg <= math.MaxUint8:
		*out = append(*out, m|24, byte(arg))
	case arg <= math.MaxUint16:
		*out = binary.BigEndian.AppendUint16(append(*out, m|25), uint16(arg))
	case arg <= math.MaxUint32:
		*out = binary.BigEndian.AppendUint32(append(*out, m|26), uint32(arg))
	default:
		*out = binary.BigEndian.AppendUint64(append(*out, m|27), arg)
	}
}

func encode(out *[]byte, v any) error {
	switch x := v.(type) {
	case nil:
		*out = append(*out, 0xf6)
	case bool:
		if x {
			*out = append(*out, 0xf5)
		} else {
			*out = append(*out, 0xf4)
		}
	case uint64:
		putHead(out, 0, x)
	case uint32:
		putHead(out, 0, uint64(x))
	case int:
		return encode(out, int64(x))
	case int64:
		if x >= 0 {
			putHead(out, 0, uint64(x))
		} else {
			putHead(out, 1, uint64(-1-x))
		}
	case []byte:
		putHead(out, 2, uint64(len(x)))
		*out = append(*out, x...)
	case string:
		putHead(out, 3, uint64(len(x)))
		*out = append(*out, x...)
	case []any:
		putHead(out, 4, uint64(len(x)))
		for _, e := range x {
			if err := encode(out, e); err != nil {
				return err
			}
		}
	case Map:
		putHead(out, 5, uint64(len(x)))
		for _, p := range x {
			if err := encode(out, p.Key); err != nil {
				return err
			}
			if err := encode(out, p.Value); err != nil {
				return err
			}
		}
	case map[string]any:
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		m := make(Map, 0, len(keys))
		for _, k := range keys {
			m = append(m, Pair{k, x[k]})
		}
		return encode(out, m)
	default:
		return fmt.Errorf("cbor: cannot encode %T", v)
	}
	return nil
}

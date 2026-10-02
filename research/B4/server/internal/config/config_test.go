package config

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

// `smserver switch` is run from root shells and install scripts with umask
// 077. The config must still come out readable by Caddy.
func TestSetUnderStrictUmaskIsWorldReadable(t *testing.T) {
	old := syscall.Umask(0o077)
	defer syscall.Umask(old)
	path := filepath.Join(t.TempDir(), "api", "v1", "config.json")
	for _, on := range []bool{true, false} {
		if _, err := Set(path, ServiceAttest, on); err != nil {
			t.Fatal(err)
		}
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0o644 {
			t.Fatalf("config.json mode %v after switch %v, want 0644", info.Mode().Perm(), on)
		}
	}
}

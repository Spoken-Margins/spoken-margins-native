package publicfs

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

// The regression from the first VPS deploy: a writer with umask 077 made
// config.json 0600 and Caddy answered 403.
func TestWorldReadableUnderStrictUmask(t *testing.T) {
	old := syscall.Umask(0o077)
	defer syscall.Umask(old)

	root := t.TempDir()
	os.Chmod(root, DirMode)
	path := filepath.Join(root, "api", "v1", "config.json")
	for i := 0; i < 2; i++ { // create, then replace
		if err := WriteFile(path, []byte(`{"serial":1}`)); err != nil {
			t.Fatal(err)
		}
		if info, _ := os.Stat(path); info.Mode().Perm() != FileMode {
			t.Fatalf("write %d: file mode %v, want %v", i, info.Mode().Perm(), os.FileMode(FileMode))
		}
	}
	for _, d := range []string{filepath.Join(root, "api"), filepath.Join(root, "api", "v1")} {
		if info, _ := os.Stat(d); info.Mode().Perm() != DirMode {
			t.Fatalf("%s: dir mode %v, want %v", d, info.Mode().Perm(), os.FileMode(DirMode))
		}
	}
	entries, _ := os.ReadDir(filepath.Dir(path))
	if len(entries) != 1 {
		t.Fatalf("temp files left behind: %v", entries)
	}
}

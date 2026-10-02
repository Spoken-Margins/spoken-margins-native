// Package publicfs writes the files Caddy serves to everyone (the kill-switch
// config and the bridge manifest). Caddy runs as another user, so these must
// be world-readable whatever umask the writer has: the admin CLI is often run
// from a root shell or an install script with umask 077, and the first VPS
// deploy rolled back because config.json came out 0600.
package publicfs

import (
	"os"
	"path/filepath"
)

const (
	FileMode = 0o644
	DirMode  = 0o755
)

// WriteFile replaces path atomically with data, mode 0644. Any directories it
// has to create get 0755. Existing directories are left alone.
func WriteFile(path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := mkdirAll(dir); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".public-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	// Explicit, because CreateTemp's 0600 and the umask would otherwise win.
	if err := tmp.Chmod(FileMode); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

func mkdirAll(dir string) error {
	if info, err := os.Stat(dir); err == nil && info.IsDir() {
		return nil
	}
	if err := mkdirAll(filepath.Dir(dir)); err != nil {
		return err
	}
	if err := os.Mkdir(dir, DirMode); err != nil && !os.IsExist(err) {
		return err
	}
	return os.Chmod(dir, DirMode)
}

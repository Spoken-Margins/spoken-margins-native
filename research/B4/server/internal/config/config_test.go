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

func TestLinkServiceIsOffAndCanBeSwitched(t *testing.T) {
	d := Default()
	if _, ok := d.Services[ServiceLinks]; !ok || d.Enabled(ServiceLinks) {
		t.Fatal("links must be present and off")
	}
	path := filepath.Join(t.TempDir(), "config.json")
	for _, on := range []bool{true, false} {
		d, err := Set(path, ServiceLinks, on)
		if err != nil || d.Enabled(ServiceLinks) != on || !d.Enabled(ServiceAttest) || !d.Enabled(ServiceBridge) {
			t.Fatalf("switch: %v %v", d, err)
		}
	}
}

// The owner switches maps on for build 33 and up in one command: one serial
// bump, and later on/off flips keep the minimum until it is changed.
func TestSwitchSetsAndKeepsMinimumBuild(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	d, err := SetWithMinimumBuild(path, ServiceMaps, true, 33)
	if err != nil || !d.Enabled(ServiceMaps) || d.Services[ServiceMaps].MinimumBuild != 33 || d.Serial != 2 {
		t.Fatalf("on with minimum: %+v %v", d, err)
	}
	if got := d.Summary(); got != "serial 2: attest=on bridge=on links=off maps=on(build>=33)" {
		t.Fatalf("summary %q", got)
	}
	d, err = Set(path, ServiceMaps, false)
	if err != nil || d.Enabled(ServiceMaps) || d.Services[ServiceMaps].MinimumBuild != 33 || d.Serial != 3 {
		t.Fatalf("off must keep the minimum: %+v %v", d, err)
	}
	d, err = SetWithMinimumBuild(path, ServiceMaps, true, 0)
	if err != nil || d.Services[ServiceMaps].MinimumBuild != 0 || d.Serial != 4 {
		t.Fatalf("0 must remove the minimum: %+v %v", d, err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := SetWithMinimumBuild(path, ServiceMaps, true, -2); err == nil {
		t.Fatal("a negative minimum other than keep must be refused")
	}
	after, _ := os.ReadFile(path)
	if string(after) != string(data) {
		t.Fatal("a refused minimum must leave the file untouched")
	}
}

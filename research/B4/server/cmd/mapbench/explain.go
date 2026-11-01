//go:build mapbench

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"spokenmargins.dev/bridge/internal/maps"
)

// explainNames prints, for each generated scene that failed the name check,
// the word the check flagged. It reads and prints only from the cache, for
// a person at the terminal; nothing goes to the results file.
func explainNames(cache string, e Episode, label string) error {
	t, _, err := loadEpisode(cache, e)
	if err != nil {
		return err
	}
	data, err := os.ReadFile(filepath.Join(cache, "generated", e.Slug+"."+label+".json"))
	if err != nil {
		return err
	}
	var gen []GenScene
	if err := json.Unmarshal(data, &gen); err != nil {
		return err
	}
	for i, g := range gen {
		if g.Check != "ungrounded name" {
			continue
		}
		var b strings.Builder
		for _, s := range t.Segments {
			end := t.DurationMs
			if i+1 < len(gen) {
				end = gen[i+1].StartMs
			}
			if s.StartMs >= g.StartMs && s.StartMs < end {
				b.WriteString(s.Text + " ")
			}
		}
		fmt.Printf("%s %s: summary %q title %q\n", e.Slug, clockOf(g.StartMs), maps.BenchUngroundedName(g.Summary, b.String()), maps.BenchUngroundedName(g.Title, b.String()))
	}
	return nil
}

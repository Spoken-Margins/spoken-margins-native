package maps

import (
	"fmt"
	"strings"
	"testing"
)

// Each bound of the upload and of the model's answer, tried on both sides:
// the largest accepted value and the first refused one. The refusal table in
// maps_test.go covers many fields but not these.
func TestTranscriptBoundsAreExact(t *testing.T) {
	accept := func(name string, change func(*Transcript)) {
		t.Helper()
		tr := testTranscript()
		change(&tr)
		if _, err := ParseTranscript(encode(t, tr)); err != nil {
			t.Errorf("%s: refused: %v", name, err)
		}
	}
	refuse := func(name string, change func(*Transcript)) {
		t.Helper()
		tr := testTranscript()
		change(&tr)
		if _, err := ParseTranscript(encode(t, tr)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}

	// Duration: "a typo can't claim a week-long episode", and it bounds the
	// arithmetic that makes scenes.
	accept("duration at the maximum", func(tr *Transcript) { tr.DurationMs = MaxDurationMs })
	refuse("duration one past the maximum", func(tr *Transcript) { tr.DurationMs = MaxDurationMs + 1 })
	refuse("a week-long episode", func(tr *Transcript) { tr.DurationMs = 7 * 24 * 3600 * 1000 })
	refuse("a duration that overflows when doubled", func(tr *Transcript) { tr.DurationMs = 1<<62 + 1 })
	refuse("negative duration", func(tr *Transcript) { tr.DurationMs = -1 })

	// A segment may not run past the maximum duration either.
	accept("last segment ends at the maximum", func(tr *Transcript) {
		tr.DurationMs = MaxDurationMs
		tr.Segments[19].EndMs = MaxDurationMs
	})
	refuse("last segment ends one past the maximum", func(tr *Transcript) {
		tr.DurationMs = MaxDurationMs
		tr.Segments[19].EndMs = MaxDurationMs + 1
	})
	refuse("segment ends far past the maximum", func(tr *Transcript) { tr.Segments[19].EndMs = 1 << 62 })
	refuse("segment starts before zero", func(tr *Transcript) { tr.Segments[0].StartMs = -1 })

	// Language: letters, digits and hyphens, at most 35 characters.
	accept("a language tag of 35 characters", func(tr *Transcript) { tr.Language = strings.Repeat("a", 35) })
	accept("a regional language tag", func(tr *Transcript) { tr.Language = "zh-Hans-CN" })
	refuse("a language tag of 36 characters", func(tr *Transcript) { tr.Language = strings.Repeat("a", 36) })
	for _, language := range []string{"en_US", "en US", "<script>", "en\n", "en;x", "é", "en/../x"} {
		refuse(fmt.Sprintf("language %q", language), func(tr *Transcript) { tr.Language = language })
	}

	// Segment count and ids.
	accept("3000 segments", func(tr *Transcript) {
		tr.Segments = nil
		for i := 0; i < MaxSegments; i++ {
			tr.Segments = append(tr.Segments, Segment{ID: fmt.Sprint(i), StartMs: int64(i), EndMs: int64(i + 1)})
		}
	})
	accept("a segment id of 64 characters", func(tr *Transcript) { tr.Segments[3].ID = strings.Repeat("s", 64) })
	refuse("a segment id of 65 characters", func(tr *Transcript) { tr.Segments[3].ID = strings.Repeat("s", 65) })
	refuse("an empty segment id", func(tr *Transcript) { tr.Segments[3].ID = "" })
}

func TestSceneCountIsBounded(t *testing.T) {
	for _, c := range []struct {
		minutes float64
		want    int
	}{
		{1, MinScenes}, {17, MinScenes}, {17.5, 4}, {20, 4}, {60, 12}, {197, 39}, {198, MaxScenes}, {48 * 60, MaxScenes},
	} {
		if got := sceneCount(int64(c.minutes * 60000)); got != c.want {
			t.Errorf("%v minutes: %d scenes, want %d", c.minutes, got, c.want)
		}
	}
}

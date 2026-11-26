package links

import (
	"strings"
	"testing"
)

// The tag block is a constant: no template action and no script, so nothing in it can come from a request (#5271).
func TestPreviewTagsAreConstant(t *testing.T) {
	tags := string(PreviewTags)
	for _, bad := range []string{"{{", "<script", "<style"} {
		if strings.Contains(tags, bad) {
			t.Errorf("PreviewTags holds %q: %s", bad, tags)
		}
	}
	if !strings.Contains(tags, `property="og:image" content="https://spokenmargins.com/l/card.png"`) {
		t.Errorf("PreviewTags has no og:image: %s", tags)
	}
}

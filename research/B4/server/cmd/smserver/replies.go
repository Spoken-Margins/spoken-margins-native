package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"path/filepath"
	"time"

	"spokenmargins.dev/bridge/internal/clubs"
)

const repliesUsage = "usage: smserver replies count -state DIR"

// repliesCommand is the owner's closed-loop measure for reply boxes (#4675, docs/design/reply-mailbox.md
// answer 6). `replies count` prints two numbers worked out from the clubs folder as it runs: the reply
// boxes it holds now and how many of them have had at least one answer. It names no box, stores nothing,
// and is not reachable over HTTP. Boxes end with their links (plus seven days), so it covers about the
// last 37 days.
func repliesCommand(args []string, out io.Writer, now time.Time) error {
	if len(args) == 0 || args[0] != "count" {
		return errors.New(repliesUsage)
	}
	fs := flag.NewFlagSet("replies count", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	state := fs.String("state", "state", "state directory")
	if err := fs.Parse(args[1:]); err != nil || fs.NArg() != 0 {
		return errors.New(repliesUsage)
	}
	st, err := clubs.OpenStore(filepath.Join(*state, "clubs"))
	if err != nil {
		return err
	}
	boxes, answered, err := st.ReplyCounts(now)
	if err != nil {
		return err
	}
	fmt.Fprintf(out, "reply boxes: %d\nwith at least one answer: %d\n", boxes, answered)
	return nil
}

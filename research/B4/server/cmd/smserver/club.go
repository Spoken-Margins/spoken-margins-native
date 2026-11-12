package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"spokenmargins.dev/bridge/internal/clubs"
)

const clubUsage = "usage: smserver club disable|takedown|hold|show-reported-link|release-hold -state DIR ... (see docs/legal/cybertipline-runbook.md)"

// clubCommand is the owner's side of club reports (#1799, docs/design/club-mailbox.md section 7 point 4).
// Nothing here opens a club's content. All of it works on the clubs folder under -state, so it runs from
// a separate process while the server is up.
//
//	disable ID [POST]       stop a club, or one post of it, being served; the content stays 30 days (a club)
//	                        or until the club ends (a post), so a hold can still be made
//	takedown ID             end a club at once and delete its content
//	hold -report ID ...     hold a club for a year and end it (the report form does this for abuse material)
//	show-reported-link ID   print the reported invite links kept for a held club
//	release-hold -reason .. end a hold early and delete the held copy
//
// Turning every club off at once is `smserver switch -public DIR clubs off`.
func clubCommand(args []string, out io.Writer, now time.Time) error {
	if len(args) == 0 {
		return errors.New(clubUsage)
	}
	sub, rest := args[0], args[1:]
	fs := flag.NewFlagSet("club "+sub, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	state := fs.String("state", "state", "state directory")
	report := fs.String("report", "", "the CyberTipline report id")
	linkFile := fs.String("link-file", "", "file holding the full reported invite link, or - for stdin")
	reason := fs.String("reason", "", "why the hold ends early (goes in the access log)")
	if err := fs.Parse(rest); err != nil {
		return errors.New(clubUsage)
	}
	st, err := clubs.OpenStore(filepath.Join(*state, "clubs"))
	if err != nil {
		return err
	}
	id := fs.Arg(0)
	switch sub {
	case "disable":
		if fs.NArg() != 1 && fs.NArg() != 2 {
			return errors.New("usage: smserver club disable -state DIR ID [POST]")
		}
		if fs.NArg() == 2 {
			post, err := strconv.Atoi(fs.Arg(1))
			if err != nil || post < 1 || strconv.Itoa(post) != fs.Arg(1) {
				return errors.New("POST must be a post number, 1 or more")
			}
			if err := st.DisablePostByOwner(id, post, now); err != nil {
				return clubError(err)
			}
			fmt.Fprintln(out, "post disabled; its bytes are kept until the club ends")
			return nil
		}
		if err := st.Disable(id, now); err != nil {
			return clubError(err)
		}
		fmt.Fprintln(out, "club disabled; its content is kept for 30 days")
	case "takedown":
		if fs.NArg() != 1 {
			return errors.New("usage: smserver club takedown -state DIR ID")
		}
		if err := st.Takedown(id, now); err != nil {
			return clubError(err)
		}
		fmt.Fprintln(out, "club ended and its content deleted")
	case "hold":
		if fs.NArg() != 1 || *report == "" {
			return errors.New("usage: smserver club hold -state DIR -report REPORTID [-link-file FILE|-] ID")
		}
		var full []byte
		switch *linkFile {
		case "":
		case "-":
			data, err := io.ReadAll(io.LimitReader(os.Stdin, maxReportedLink+1))
			if err != nil {
				return err
			}
			full = data
		default:
			data, err := os.ReadFile(*linkFile)
			if err != nil {
				return err
			}
			full = data
		}
		if *linkFile != "" && (len(full) == 0 || len(full) > maxReportedLink) {
			return fmt.Errorf("the reported link must be between 1 and %d bytes", maxReportedLink)
		}
		if err := st.HoldByOwner(id, *report, full, now); err != nil {
			return clubError(err)
		}
		fmt.Fprintln(out, "club ended and held for one year")
	case "show-reported-link":
		if fs.NArg() != 1 {
			return errors.New("usage: smserver club show-reported-link -state DIR ID")
		}
		found, err := st.ReportedLinks(id, now)
		if err != nil {
			return clubError(err)
		}
		if len(found) == 0 {
			fmt.Fprintln(out, "no reported link was kept for this hold; the report did not send one, or it was dropped")
			return nil
		}
		for i, link := range found {
			shown := oneLine(string(link))
			note := ""
			if shown != string(link) {
				note = "   [altered: control or invisible characters shown as spaces]"
			}
			fmt.Fprintf(out, "%d: %s%s\n", i+1, shown, note)
		}
		fmt.Fprintf(out, "%d reported link(s). Open none of them; forward them to the CyberTipline.\n", len(found))
	case "release-hold":
		if fs.NArg() != 1 || *reason == "" {
			return errors.New("usage: smserver club release-hold -state DIR -reason TEXT ID")
		}
		if err := st.ReleaseHeld(id, *reason, now); err != nil {
			return clubError(err)
		}
		fmt.Fprintln(out, "hold ended and the held copy deleted")
	default:
		return errors.New(clubUsage)
	}
	return nil
}

// clubError puts a store error in the owner's words.
func clubError(err error) error {
	switch {
	case errors.Is(err, clubs.ErrNotFound):
		return errors.New("no such club, or no such post")
	case errors.Is(err, clubs.ErrGone):
		return errors.New("that club has already ended; its content is gone")
	}
	return err
}

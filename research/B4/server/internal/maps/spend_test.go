package maps

import (
	"context"
	"fmt"
	"path/filepath"
	"testing"
)

// The money guards of the worker. Each is a promise in a code comment that a
// normal run never tests, because the ledger always writes, the fake API
// reports only plain tokens and always finishes its answer.

func queueEpisodes(t *testing.T, svc *Service, n int) []string {
	t.Helper()
	var keys []string
	for i := 0; i < n; i++ {
		tr := testTranscript()
		tr.EpisodeKey = fmt.Sprintf("%064x", i+1)
		if err := svc.Store.PutTranscript(tr, svc.Now()); err != nil {
			t.Fatal(err)
		}
		keys = append(keys, tr.EpisodeKey)
	}
	return keys
}

// "A ledger that couldn't be written counts as past the cap, so a disk
// problem can never lead to unrecorded spending": after the first call whose
// cost can't be recorded, the worker makes no more calls and takes no more
// uploads, though the month's total is nowhere near the cap.
func TestUnwritableLedgerStopsAllFurtherCalls(t *testing.T) {
	api := newFakeAPI(t, goodAnswer)
	svc, _, logs := newService(t, api, 10)
	svc.Ledger.path = filepath.Join(t.TempDir(), "no-such-directory", "ledger.json")
	keys := queueEpisodes(t, svc, 3)

	svc.ProcessWaiting(context.Background())

	if api.callCount() != 1 {
		t.Fatalf("%d paid calls after the ledger stopped writing, want 1", api.callCount())
	}
	if !containsAny(*logs, "no more calls until a restart") {
		t.Fatalf("log doesn't say the worker halted: %v", *logs)
	}
	for _, key := range keys {
		if svc.Store.HasMap(key) || svc.Store.HasTranscript(key) {
			t.Errorf("episode %s... left a map or a waiting transcript", key[:4])
		}
	}
	// New uploads are refused the way the cap refuses them.
	if out, _ := svc.Submit(testTranscript()); out != CapReached {
		t.Fatalf("submit after the halt = %v, want CapReached", out)
	}
	svc.Store.PutTranscript(testTranscript(), svc.Now())
	svc.ProcessWaiting(context.Background())
	if api.callCount() != 1 {
		t.Fatalf("%d paid calls after the halt, want 1", api.callCount())
	}
}

// "Cache writes and reads count at the full input price: the ledger may
// overstate, never understate."
func TestCacheTokensAreBilledAtTheFullInputPrice(t *testing.T) {
	api := newFakeAPI(t, goodAnswer)
	api.cacheWrite, api.cacheRead = 1000, 4000
	svc, _, _ := newService(t, api, 10)
	svc.Submit(testTranscript())
	svc.ProcessWaiting(context.Background())

	// (13000 + 1000 + 4000) input at $1/MTok + 2000 output at $5/MTok.
	if spent := svc.Ledger.Spent(svc.Now()); spent != 18000+10000 {
		t.Fatalf("ledger = %d, want 28000 (cache tokens at the input price)", spent)
	}
}

// An answer that stopped for any reason but finishing (out of tokens, a
// refusal) is billed and then dropped, even when what it says would pass the
// checks: it may be a partial map.
func TestAnswerThatDidNotFinishIsBilledButNeverMadeIntoAMap(t *testing.T) {
	for _, reason := range []string{"max_tokens", "refusal"} {
		t.Run(reason, func(t *testing.T) {
			api := newFakeAPI(t, goodAnswer) // a complete, valid answer, except for how it stopped
			api.stopReason = reason
			svc, _, logs := newService(t, api, 10)
			svc.Submit(testTranscript())
			svc.ProcessWaiting(context.Background())

			if svc.Store.HasMap(testKey) {
				t.Fatalf("a map was made from an answer that stopped with %q", reason)
			}
			if api.callCount() != attemptsPerEpisode {
				t.Fatalf("calls = %d, want %d", api.callCount(), attemptsPerEpisode)
			}
			if spent := svc.Ledger.Spent(svc.Now()); spent != int64(attemptsPerEpisode)*23000 {
				t.Fatalf("ledger = %d, want both attempts billed", spent)
			}
			if !containsAny(*logs, "answer cut off or declined") {
				t.Fatalf("log doesn't say why: %v", *logs)
			}
		})
	}

	// The same answer finishing normally does become a map.
	api := newFakeAPI(t, goodAnswer)
	svc, _, _ := newService(t, api, 10)
	svc.Submit(testTranscript())
	svc.ProcessWaiting(context.Background())
	if !svc.Store.HasMap(testKey) {
		t.Fatal("control: a finished answer made no map")
	}
}

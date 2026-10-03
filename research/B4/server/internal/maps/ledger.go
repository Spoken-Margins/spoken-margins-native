package maps

import (
	"encoding/json"
	"errors"
	"math"
	"os"
	"sync"
	"time"
)

// Prices are what the provider charges, in US dollars per million tokens.
// They are server settings, so a price change needs no new build.
type Prices struct {
	InputPerMTok  float64
	OutputPerMTok float64
}

// Cost is a call's cost in micro-dollars, rounded up. At one dollar per
// million tokens a token costs exactly one micro-dollar, so whole numbers
// keep the ledger free of float drift.
func (p Prices) Cost(inputTokens, outputTokens int64) int64 {
	return int64(math.Ceil(float64(inputTokens)*p.InputPerMTok + float64(outputTokens)*p.OutputPerMTok))
}

// USDToMicro converts a dollar setting to micro-dollars.
func USDToMicro(usd float64) int64 { return int64(math.Round(usd * 1e6)) }

// Ledger is the month's spend, kept on disk so a restart can't reset it.
// A new UTC month starts from zero.
type Ledger struct {
	path string
	mu   sync.Mutex
	doc  ledgerDoc
}

type ledgerDoc struct {
	Month         string `json:"month"` // 2006-01, UTC
	SpentMicroUSD int64  `json:"spentMicroUSD"`
	Calls         int64  `json:"calls"`
}

const monthFormat = "2006-01"

// OpenLedger reads the ledger at path. A missing file is an empty month; an
// unreadable one is an error, so a damaged ledger can never mean "nothing
// spent" (the server then makes no calls until the owner looks).
func OpenLedger(path string) (*Ledger, error) {
	l := &Ledger{path: path}
	data, err := os.ReadFile(path)
	switch {
	case errors.Is(err, os.ErrNotExist):
		return l, nil
	case err != nil:
		return nil, err
	}
	if err := json.Unmarshal(data, &l.doc); err != nil {
		return nil, err
	}
	return l, nil
}

func (l *Ledger) roll(now time.Time) {
	if month := now.UTC().Format(monthFormat); l.doc.Month != month {
		l.doc = ledgerDoc{Month: month}
	}
}

// Spent is this month's total in micro-dollars.
func (l *Ledger) Spent(now time.Time) int64 {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.roll(now)
	return l.doc.SpentMicroUSD
}

// Add records a call's cost and writes the ledger before returning.
func (l *Ledger) Add(now time.Time, microUSD int64) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.roll(now)
	l.doc.SpentMicroUSD += microUSD
	l.doc.Calls++
	data, err := json.Marshal(l.doc)
	if err != nil {
		return err
	}
	return writeAtomic(l.path, append(data, '\n'))
}

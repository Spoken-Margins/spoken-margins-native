package main

import (
	"flag"
	"path/filepath"

	"spokenmargins.dev/bridge/internal/maps"
)

// mapsKeyEnv names the variable the service's environment file sets
// (deploy/smserver.service). It is never a flag, so the key can't show up in
// the process list, and never in config.json.
const mapsKeyEnv = "ANTHROPIC_API_KEY"

// mapsFlags are the private listening-map settings (#551). They live in the
// service's command line on the box, never in the public config.json.
type mapsFlags struct {
	capUSD        float64
	model         string
	inputPerMTok  float64
	outputPerMTok float64
	apiBase       string
}

func (m *mapsFlags) register(fs *flag.FlagSet) {
	fs.Float64Var(&m.capUSD, "maps-cap-usd", 10, "hard monthly cap on map-making spend, in US dollars")
	fs.StringVar(&m.model, "maps-model", maps.DefaultModel, "model that makes listening maps")
	fs.Float64Var(&m.inputPerMTok, "maps-input-usd-per-mtok", 0.10, "the model's input price, US dollars per million tokens")
	fs.Float64Var(&m.outputPerMTok, "maps-output-usd-per-mtok", 0.50, "the model's output price, US dollars per million tokens")
	fs.StringVar(&m.apiBase, "maps-api-base", "", "provider base URL (local testing only)")
}

// setupMaps opens the map store and, when there is an API key, the service
// that makes maps. Without a key the server still serves stored maps and
// refuses uploads. Nothing it logs includes the key.
func setupMaps(stateDir string, f mapsFlags, apiKey string, logf func(string, ...any)) (*maps.Store, *maps.Service, error) {
	dir := filepath.Join(stateDir, "maps")
	store, err := maps.OpenStore(dir)
	if err != nil {
		return nil, nil, err
	}
	if apiKey == "" {
		logf("maps: no API key, so uploads are refused; stored maps are still served")
		return store, nil, nil
	}
	provider, err := maps.NewAnthropic(apiKey, f.model, f.apiBase)
	if err != nil {
		logf("maps: %v; uploads are refused", err)
		return store, nil, nil
	}
	ledger, err := maps.OpenLedger(filepath.Join(dir, "ledger.json"))
	if err != nil {
		// A damaged ledger must never read as "nothing spent".
		logf("maps: can't read the spend ledger (%v); uploads are refused until it is fixed", err)
		return store, nil, nil
	}
	svc := &maps.Service{
		Store:       store,
		Ledger:      ledger,
		Provider:    provider,
		Prices:      maps.Prices{InputPerMTok: f.inputPerMTok, OutputPerMTok: f.outputPerMTok},
		CapMicroUSD: maps.USDToMicro(f.capUSD),
		Logf:        logf,
	}
	logf("maps: making maps with %s, capped at $%.2f a month", provider.Generator(), f.capUSD)
	return store, svc, nil
}

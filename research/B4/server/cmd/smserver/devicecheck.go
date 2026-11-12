package main

import (
	"errors"
	"fmt"
	"os"
	"strings"

	"spokenmargins.dev/bridge/internal/api"
	"spokenmargins.dev/bridge/internal/devicecheck"
)

// setupDeviceCheck builds the DeviceCheck client from the three serve flags (#1728). With none of
// them set it returns nil and the server never asks an app for a device token. With some but not all,
// or an unreadable key, it fails rather than starting with the ladder's reinstall guard silently off.
// The team id is the part of -app-id before its first dot.
func setupDeviceCheck(keyPath, keyID, appID string, development bool) (api.DeviceChecker, error) {
	if keyPath == "" && keyID == "" {
		if development {
			return nil, errors.New("devicecheck: -devicecheck-development needs -devicecheck-key and -devicecheck-key-id")
		}
		return nil, nil
	}
	if keyPath == "" || keyID == "" {
		return nil, errors.New("devicecheck: -devicecheck-key and -devicecheck-key-id go together")
	}
	team, _, ok := strings.Cut(appID, ".")
	if !ok || team == "" {
		return nil, fmt.Errorf("devicecheck: cannot read a team id from -app-id %q", appID)
	}
	data, err := os.ReadFile(keyPath)
	if err != nil {
		return nil, fmt.Errorf("devicecheck: %w", err)
	}
	key, err := devicecheck.ParseKeyPEM(data)
	if err != nil {
		return nil, err
	}
	c := &devicecheck.Client{TeamID: team, KeyID: keyID, Key: key}
	if development {
		c.BaseURL = devicecheck.DevelopmentURL
	}
	return c, nil
}

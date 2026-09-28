package manifest

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

const fixture = "../../../contracts/fixtures/bridge-manifest.example.json"

func load(t *testing.T) map[string]any {
	t.Helper()
	data, err := os.ReadFile(fixture)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func firstSource(m map[string]any) map[string]any {
	return m["sources"].([]any)[0].(map[string]any)
}

func TestFixtureIsValid(t *testing.T) {
	data, _ := os.ReadFile(fixture)
	m, err := Validate(data)
	if err != nil {
		t.Fatal(err)
	}
	if len(m.Sources) != 2 {
		t.Fatalf("sources %d", len(m.Sources))
	}
}

func TestRefusals(t *testing.T) {
	cases := map[string]struct {
		mutate func(m map[string]any)
		want   string
	}{
		"article body on an item": {func(m map[string]any) {
			firstSource(m)["items"].([]any)[0].(map[string]any)["content"] = "<p>The whole article</p>"
		}, `unknown field "content"`},
		"summary on an item": {func(m map[string]any) {
			firstSource(m)["items"].([]any)[0].(map[string]any)["summary"] = "An excerpt"
		}, `unknown field "summary"`},
		"script in a recipe": {func(m map[string]any) {
			firstSource(m)["recipe"].(map[string]any)["script"] = "document.body.innerText"
		}, `unknown field "script"`},
		"javascript in a selector": {func(m map[string]any) {
			firstSource(m)["recipe"].(map[string]any)["content"] = []any{"a[href^='javascript:']"}
		}, `contains "javascript:"`},
		"selector breaking out of a string": {func(m map[string]any) {
			firstSource(m)["recipe"].(map[string]any)["title"] = "h1`);fetch(`x"
		}, "selector"},
		"item on another host": {func(m map[string]any) {
			firstSource(m)["items"].([]any)[0].(map[string]any)["url"] = "https://tracker.example.net/p/x"
		}, "must be https on one of the source's match hosts"},
		"plain http item": {func(m map[string]any) {
			firstSource(m)["items"].([]any)[0].(map[string]any)["url"] = "http://essays.example.org/p/x"
		}, "must be https"},
		"ip address host": {func(m map[string]any) {
			firstSource(m)["match"].(map[string]any)["hosts"] = []any{"10.0.0.1"}
		}, "not a lowercase DNS name"},
		"our own domain as a source host": {func(m map[string]any) {
			firstSource(m)["match"].(map[string]any)["hosts"] = []any{"essays.example.org", "spokenmargins.proximitytoprogress.com"}
		}, "is a Spoken Margins domain"},
		"unknown extract mode": {func(m map[string]any) {
			firstSource(m)["recipe"].(map[string]any)["extract"] = "eval"
		}, `extract "eval"`},
		"per-source icon served by us": {func(m map[string]any) {
			firstSource(m)["icon"] = "https://spokenmargins.proximitytoprogress.com/icons/example.png"
		}, `unknown field "icon"`},
	}
	for name, c := range cases {
		m := load(t)
		c.mutate(m)
		data, _ := json.Marshal(m)
		_, err := Validate(data)
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: want error containing %q, got %v", name, c.want, err)
		}
	}
}

func TestPublishRefusesWithoutTouchingTheLiveFile(t *testing.T) {
	dir := t.TempDir()
	live := dir + "/bridge/v1/manifest.json"
	good, _ := os.ReadFile(fixture)
	if _, err := Publish(live, good); err != nil {
		t.Fatal(err)
	}
	m := load(t)
	firstSource(m)["items"].([]any)[0].(map[string]any)["content"] = "body"
	bad, _ := json.Marshal(m)
	if _, err := Publish(live, bad); err == nil {
		t.Fatal("bad manifest published")
	}
	now, _ := os.ReadFile(live)
	if string(now) != string(good) {
		t.Fatal("refused publish changed the live manifest")
	}
}

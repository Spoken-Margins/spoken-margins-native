package links

import (
	"bytes"
	"strings"
	"testing"
	"time"
)

func render(t *testing.T, p Preview) string {
	t.Helper()
	var b bytes.Buffer
	err := RenderPage(&b, Page{
		ID:         "AAAAAAAAAAAAAAAAAAAAAA",
		Link:       Link{CreatedAt: time.Date(2026, 10, 3, 12, 0, 0, 0, time.UTC), Preview: p},
		InstallURL: "https://spokenmargins.example/",
	})
	if err != nil {
		t.Fatal(err)
	}
	return b.String()
}

func fixture() Preview {
	return Preview{
		Schema: PreviewSchema,
		Source: Source{Title: "The Long Walk", Show: "Field Notes", URL: "https://example.com/episodes/long-walk"},
		Margins: []Margin{
			{Text: "This is where it turns.", Before: "and then the river", After: "rose over the bank"},
			{Text: ""},
		},
	}
}

func TestPageShowsMarginsExcerptsAndAttribution(t *testing.T) {
	page := render(t, fixture())
	for _, want := range []string{
		"This is where it turns.",
		"<blockquote>…and then the river",
		"rose over the bank…",
		"Quoted from <cite>The Long Walk</cite>, Field Notes",
		`<a href="https://example.com/episodes/long-walk" rel="noopener noreferrer">The Long Walk</a>`,
		`href="https://spokenmargins.example/"`,
		`<form method="post" action="/l/AAAAAAAAAAAAAAAAAAAAAA/report">`,
		"Report this link",
		"A spoken Margin. Open it in Spoken Margins to hear it.",
		"stops working on 2 November 2026",
	} {
		if !strings.Contains(page, want) {
			t.Errorf("page is missing %q", want)
		}
	}
	for _, never := range []string{"<audio", "<video", "<script", "<iframe", "src="} {
		if strings.Contains(page, never) {
			t.Errorf("page contains %q", never)
		}
	}
}

func TestPageLeavesOutTokenSourceLinks(t *testing.T) {
	for _, raw := range []string{
		"https://feeds.example.com/episodes/1?token=s3cret",
		"https://listener:s3cret@feeds.example.com/episodes/1",
		"https://feeds.example.com/episodes/1#s3cret",
	} {
		p := fixture()
		// Straight into the renderer, as if a bad URL had been stored.
		p.Source.URL = raw
		page := render(t, p)
		if strings.Contains(page, "s3cret") || strings.Contains(page, "feeds.example.com") {
			t.Errorf("%s: page shows the URL", raw)
		}
		if !strings.Contains(page, "<h1>The Long Walk</h1>") {
			t.Errorf("%s: title should show without a link", raw)
		}
	}
}

func TestPageEscapesEverythingTheSenderWrote(t *testing.T) {
	p := fixture()
	p.Source.Title = `<b onmouseover="x()">Title</b>`
	p.Source.Show = `<script>alert("show")</script>`
	p.Margins[0] = Margin{
		Text:   `<img src=x onerror=alert(1)>`,
		Before: `</blockquote><script>alert("before")</script>`,
		After:  `<a href="javascript:alert(2)">after</a>`,
	}
	page := render(t, p)
	for _, raw := range []string{`<b onmouseover`, `<script>alert`, `<img src=x`, `</blockquote><script>`, `<a href="javascript:`} {
		if strings.Contains(page, raw) {
			t.Errorf("page contains unescaped %q", raw)
		}
	}
	if !strings.Contains(page, "&lt;img src=x onerror=alert(1)&gt;") {
		t.Error("Margin text should appear escaped")
	}
}

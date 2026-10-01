package maps

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"
)

// DefaultModel is the model the server asks unless the owner sets another.
const DefaultModel = "claude-haiku-4-5"

// Request is one map-making call: instructions, the transcript as text, and
// the JSON shape the answer must take.
type Request struct {
	System    string
	Prompt    string
	Schema    map[string]any
	MaxTokens int64
}

// Response is the provider's answer and what it billed.
type Response struct {
	Text         string
	InputTokens  int64
	OutputTokens int64
	// Complete is false when the answer was cut off or declined; the tokens
	// are still billed.
	Complete bool
}

// Provider makes one map. Small on purpose, so a second provider (or a fake
// in tests) is one type.
type Provider interface {
	// Generator names the provider and model for the map's generator field.
	Generator() string
	Generate(ctx context.Context, req Request) (Response, error)
}

// ProviderError says a call failed. It carries only the HTTP status: the
// provider's message is never logged, so nothing it echoes (an API key
// prefix, a request id) reaches the journal.
type ProviderError struct {
	Status int
	// MaybeBilled is set when the request was sent but its answer was lost
	// (a timeout, a dropped connection): the provider may have billed it,
	// so the ledger counts it and it isn't retried.
	MaybeBilled bool
}

func (e *ProviderError) Error() string {
	switch {
	case e.MaybeBilled:
		return "maps: provider answer lost"
	case e.Status == 0:
		return "maps: provider unreachable"
	}
	return fmt.Sprintf("maps: provider answered HTTP %d", e.Status)
}

// Anthropic calls Anthropic's Messages API with net/http, keeping the
// server free of third-party modules (DESIGN.md §8).
type Anthropic struct {
	apiKey  string
	model   string
	baseURL string
	client  *http.Client
	// Backoff is the wait before each retry of an overloaded or unreachable
	// call. Tests shorten it.
	Backoff []time.Duration
}

const (
	anthropicVersion = "2023-06-01"
	maxAnswerBytes   = 1 << 20
)

// NewAnthropic builds the provider from an explicit key. baseURL is for
// tests; empty means the real API.
func NewAnthropic(apiKey, model, baseURL string) (*Anthropic, error) {
	if strings.TrimSpace(apiKey) == "" {
		return nil, errors.New("maps: no API key")
	}
	if model == "" {
		model = DefaultModel
	}
	if baseURL == "" {
		baseURL = "https://api.anthropic.com"
	}
	return &Anthropic{
		apiKey: apiKey, model: model, baseURL: strings.TrimRight(baseURL, "/"),
		client:  &http.Client{Timeout: 2 * time.Minute},
		Backoff: []time.Duration{2 * time.Second, 8 * time.Second},
	}, nil
}

func (a *Anthropic) Generator() string { return "anthropic/" + a.model }

type messagesRequest struct {
	Model        string         `json:"model"`
	MaxTokens    int64          `json:"max_tokens"`
	System       string         `json:"system"`
	Messages     []message      `json:"messages"`
	OutputConfig map[string]any `json:"output_config"`
}

type message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type messagesResponse struct {
	Content []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	} `json:"content"`
	StopReason string `json:"stop_reason"`
	Usage      struct {
		InputTokens              int64 `json:"input_tokens"`
		OutputTokens             int64 `json:"output_tokens"`
		CacheCreationInputTokens int64 `json:"cache_creation_input_tokens"`
		CacheReadInputTokens     int64 `json:"cache_read_input_tokens"`
	} `json:"usage"`
}

// retryable is a failure worth one more try after a pause: rate limited,
// overloaded, a server error, or no connection. None of them bill tokens.
func retryable(e *ProviderError) bool {
	return !e.MaybeBilled && (e.Status == 0 || e.Status == http.StatusTooManyRequests || e.Status >= 500)
}

func (a *Anthropic) Generate(ctx context.Context, req Request) (Response, error) {
	body, err := json.Marshal(messagesRequest{
		Model:     a.model,
		MaxTokens: req.MaxTokens,
		System:    req.System,
		Messages:  []message{{Role: "user", Content: req.Prompt}},
		// Structured output: the answer is JSON in exactly this shape.
		OutputConfig: map[string]any{"format": map[string]any{"type": "json_schema", "schema": req.Schema}},
	})
	if err != nil {
		return Response{}, err
	}
	for attempt := 0; ; attempt++ {
		resp, err := a.call(ctx, body)
		var perr *ProviderError
		if err == nil || !errors.As(err, &perr) || !retryable(perr) || attempt >= len(a.Backoff) {
			return resp, err
		}
		select {
		case <-ctx.Done():
			return Response{}, ctx.Err()
		case <-time.After(a.Backoff[attempt]):
		}
	}
}

func (a *Anthropic) call(ctx context.Context, body []byte) (Response, error) {
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, a.baseURL+"/v1/messages", bytes.NewReader(body))
	if err != nil {
		return Response{}, err
	}
	httpReq.Header.Set("x-api-key", a.apiKey)
	httpReq.Header.Set("anthropic-version", anthropicVersion)
	httpReq.Header.Set("content-type", "application/json")
	httpResp, err := a.client.Do(httpReq)
	if err != nil {
		// A timeout means the request went out and the answer may have
		// been generated. Other failures (no route, refused) never reached
		// the provider. The error text itself is dropped.
		// A server shutdown mid-call counts the same way.
		var ne net.Error
		return Response{}, &ProviderError{MaybeBilled: ctx.Err() != nil || errors.As(err, &ne) && ne.Timeout()}
	}
	defer httpResp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(httpResp.Body, maxAnswerBytes))
	if err != nil {
		return Response{}, &ProviderError{Status: httpResp.StatusCode, MaybeBilled: httpResp.StatusCode == http.StatusOK}
	}
	if httpResp.StatusCode != http.StatusOK {
		return Response{}, &ProviderError{Status: httpResp.StatusCode}
	}
	var m messagesResponse
	if err := json.Unmarshal(data, &m); err != nil {
		return Response{}, &ProviderError{Status: httpResp.StatusCode}
	}
	// Cache writes and reads count at the full input price: the ledger may
	// overstate a little, never understate.
	resp := Response{
		InputTokens:  m.Usage.InputTokens + m.Usage.CacheCreationInputTokens + m.Usage.CacheReadInputTokens,
		OutputTokens: m.Usage.OutputTokens,
		Complete:     m.StopReason == "end_turn",
	}
	for _, block := range m.Content {
		if block.Type == "text" {
			resp.Text += block.Text
		}
	}
	return resp, nil
}

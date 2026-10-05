package api

import (
	"testing"
	"time"
)

// A refund for a reservation made before midnight doesn't eat into the new
// day's count.
func TestTokenQuotaRefundStaysInItsDay(t *testing.T) {
	var q dayQuota
	night := time.Date(2026, 10, 3, 23, 59, 59, 0, time.UTC)
	day, ok := q.reserve("tag", 10, 10, night)
	if !ok {
		t.Fatal("first reservation refused")
	}
	if _, ok := q.reserve("tag", 10, 10, night.Add(2*time.Second)); !ok {
		t.Fatal("new day's reservation refused")
	}
	q.refund("tag", 10, day)
	if _, ok := q.reserve("tag", 1, 10, night.Add(3*time.Second)); ok {
		t.Fatal("yesterday's refund freed today's allowance")
	}
}

package main

import (
	"testing"
	"time"

	"beacle/shared"
)

func electFixture() ([]shared.VPS, map[string]int) {
	t0 := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	cands := []shared.VPS{
		{ID: "home1", Name: "home1", PublicIP: "83.1.1.1", CreatedAt: t0},
		{ID: "home2", Name: "home2", PublicIP: "83.1.1.1", CreatedAt: t0.Add(time.Hour)},
		{ID: "hetz", Name: "hetz", PublicIP: "5.9.9.9", CreatedAt: t0.Add(2 * time.Hour)},
		{ID: "ovh", Name: "ovh", PublicIP: "51.1.1.1", CreatedAt: t0.Add(3 * time.Hour)},
	}
	// The two home servers are the most stable — the case that used to put
	// both seats behind one router.
	coverage := map[string]int{"home1": 100, "home2": 99, "hetz": 50, "ovh": 40}
	return cands, coverage
}

func ids(p, s *shared.VPS) (string, string) {
	a, b := "", ""
	if p != nil {
		a = p.ID
	}
	if s != nil {
		b = s.ID
	}
	return a, b
}

func TestElectSplitsNetworks(t *testing.T) {
	cands, cov := electFixture()
	p, s := ids(electWatchers(cands, cov, "", ""))
	if p != "home1" || s != "hetz" {
		t.Fatalf("got %s + %s, want home1 + hetz (one at home, one outside)", p, s)
	}
}

func TestElectSameNetworkWhenNothingElse(t *testing.T) {
	cands, cov := electFixture()
	p, s := ids(electWatchers(cands[:2], cov, "", ""))
	if p != "home1" || s != "home2" {
		t.Fatalf("got %s + %s, want home1 + home2 — a backup in the same network beats none", p, s)
	}
}

func TestElectUnknownNetworkIsNotShared(t *testing.T) {
	cands, cov := electFixture()
	cands[1].PublicIP = ""
	cands[0].PublicIP = ""
	p, s := ids(electWatchers(cands, cov, "", ""))
	if p != "home1" || s != "home2" {
		t.Fatalf("got %s + %s: servers with no known address must not count as one network", p, s)
	}
}

func TestElectIPv6GroupsBySlash64(t *testing.T) {
	a := shared.VPS{PublicIP: "2a01:4f8:1:2::10"}
	b := shared.VPS{PublicIP: "2a01:4f8:1:2::20"}
	c := shared.VPS{PublicIP: "2a01:4f8:1:3::20"}
	if !sameNetwork(a, b) {
		t.Error("two addresses in one /64 should share a network")
	}
	if sameNetwork(a, c) {
		t.Error("different /64s should not share a network")
	}
}

func TestElectPinnedPrimary(t *testing.T) {
	cands, cov := electFixture()
	p, s := ids(electWatchers(cands, cov, "ovh", ""))
	if p != "ovh" || s != "home1" {
		t.Fatalf("got %s + %s, want ovh (pinned) + home1", p, s)
	}
}

func TestElectPinnedSecondaryShapesPrimary(t *testing.T) {
	cands, cov := electFixture()
	p, s := ids(electWatchers(cands, cov, "", "home2"))
	if s != "home2" || p != "hetz" {
		t.Fatalf("got %s + %s, want hetz + home2 (pinned): the automatic seat avoids the pinned one's network", p, s)
	}
}

func TestElectBothPinnedSameNetworkHonoured(t *testing.T) {
	cands, cov := electFixture()
	p, s := ids(electWatchers(cands, cov, "home2", "home1"))
	if p != "home2" || s != "home1" {
		t.Fatalf("got %s + %s: an explicit choice wins over the network rule", p, s)
	}
}

func TestElectOfflinePinFallsBack(t *testing.T) {
	cands, cov := electFixture()
	p, s := ids(electWatchers(cands, cov, "gone", ""))
	if p != "home1" || s != "hetz" {
		t.Fatalf("got %s + %s, want the automatic pair while the pinned server is away", p, s)
	}
}

func TestElectEmpty(t *testing.T) {
	p, s := electWatchers(nil, nil, "x", "y")
	if p != nil || s != nil {
		t.Fatal("no candidates must elect nobody")
	}
}

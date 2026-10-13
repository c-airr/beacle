package main

import (
	"testing"
	"time"

	"beacle/shared"
)

func certSite(domain string, end time.Time) shared.ProxySite {
	return shared.ProxySite{Domain: domain, SSL: shared.SSLActive, CertNotAfter: &end}
}

func openCertAlerts(store *Store) []shared.Alert {
	var out []shared.Alert
	for _, a := range store.ListAlerts() {
		if a.Type == shared.AlertCertExpiring && !a.Resolved {
			out = append(out, a)
		}
	}
	return out
}

func TestCertAlertEscalatesAsExpiryNears(t *testing.T) {
	store, e := newStoreAndEngine(t)
	now := time.Date(2026, 10, 14, 12, 0, 0, 0, time.UTC)
	end := now.Add(10 * 24 * time.Hour)

	e.evaluateCerts(testVPS, []shared.ProxySite{certSite("a.example", end)}, now)
	open := openCertAlerts(store)
	if len(open) != 1 || open[0].Severity != shared.SeverityWarning {
		t.Fatalf("10 days left: want one warning, got %+v", open)
	}
	if open[0].Message != "Certificate for a.example expires on 2026-10-24" {
		t.Fatalf("message %q", open[0].Message)
	}

	e.evaluateCerts(testVPS, []shared.ProxySite{certSite("a.example", end)}, end.Add(-2*24*time.Hour))
	open = openCertAlerts(store)
	if len(open) != 1 || open[0].Severity != shared.SeverityCritical {
		t.Fatalf("2 days left: want the warning replaced by one critical, got %+v", open)
	}

	e.evaluateCerts(testVPS, []shared.ProxySite{certSite("a.example", end)}, end.Add(time.Hour))
	open = openCertAlerts(store)
	if len(open) != 1 || open[0].Message != "Certificate for a.example expired on 2026-10-24" {
		t.Fatalf("expired: got %+v", open)
	}
}

func TestCertAlertResolvesOnRenewalAndRemoval(t *testing.T) {
	store, e := newStoreAndEngine(t)
	now := time.Date(2026, 10, 14, 12, 0, 0, 0, time.UTC)
	soon := now.Add(5 * 24 * time.Hour)

	e.evaluateCerts(testVPS, []shared.ProxySite{certSite("a.example", soon), certSite("b.example", soon)}, now)
	if n := len(openCertAlerts(store)); n != 2 {
		t.Fatalf("want two warnings, got %d", n)
	}

	// a.example renewed, b.example deleted from the proxy.
	e.evaluateCerts(testVPS, []shared.ProxySite{certSite("a.example", now.Add(90*24*time.Hour))}, now)
	if open := openCertAlerts(store); len(open) != 0 {
		t.Fatalf("renewed and removed sites must leave no open alert, got %+v", open)
	}
}

func TestCertWithMonthsLeftRaisesNothing(t *testing.T) {
	store, e := newStoreAndEngine(t)
	now := time.Now()
	e.evaluateCerts(testVPS, []shared.ProxySite{certSite("a.example", now.Add(60*24*time.Hour)), {Domain: "plain.example"}}, now)
	if open := openCertAlerts(store); len(open) != 0 {
		t.Fatalf("got %+v", open)
	}
}

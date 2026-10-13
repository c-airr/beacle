package main

import (
	"crypto/x509"
	"crypto/x509/pkix"
	"net"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"

	"beacle/shared"
)

func TestCertTargetSkipsWhatHasNoPublicCertificate(t *testing.T) {
	cases := []struct {
		site       shared.ProxySite
		host, port string
		ok         bool
	}{
		{shared.ProxySite{Domain: "example.com", SSL: shared.SSLActive}, "example.com", "443", true},
		{shared.ProxySite{Domain: "https://Example.com:8443/api", SSL: shared.SSLActive}, "example.com", "8443", true},
		{shared.ProxySite{Domain: "example.com", SSL: shared.SSLDisabled}, "", "", false},
		{shared.ProxySite{Domain: "example.com", SSL: shared.SSLActive, TLSMode: "internal"}, "", "", false},
		{shared.ProxySite{Domain: "http://example.com", SSL: shared.SSLActive}, "", "", false},
		{shared.ProxySite{Domain: "example.com:80", SSL: shared.SSLActive}, "", "", false},
		{shared.ProxySite{Domain: "*.example.com", SSL: shared.SSLActive}, "", "", false},
		{shared.ProxySite{Domain: "10.0.0.5", SSL: shared.SSLActive}, "", "", false},
		{shared.ProxySite{Domain: "localhost", SSL: shared.SSLActive}, "", "", false},
	}
	for _, c := range cases {
		host, port, ok := certTarget(c.site)
		if ok != c.ok || host != c.host || port != c.port {
			t.Errorf("%q: got (%q, %q, %v), want (%q, %q, %v)", c.site.Domain, host, port, ok, c.host, c.port, c.ok)
		}
	}
}

func TestCertsAreReadInTheBackgroundAndThenReported(t *testing.T) {
	expires := time.Date(2026, 11, 2, 12, 0, 0, 0, time.UTC)
	c := newCertChecker()
	c.fetch = func(host, port string) (*x509.Certificate, error) {
		if host == "broken.example" {
			return nil, errNoCert
		}
		return &x509.Certificate{NotAfter: expires, Issuer: pkix.Name{Organization: []string{"Let's Encrypt"}}}, nil
	}
	sites := func() []shared.ProxySite {
		return []shared.ProxySite{
			{Domain: "a.example", SSL: shared.SSLActive},
			{Domain: "broken.example", SSL: shared.SSLActive},
		}
	}

	first := sites()
	c.annotate(first)
	if first[0].CertNotAfter != nil {
		t.Fatal("the first report must not wait for the handshake")
	}

	deadline := time.Now().Add(2 * time.Second)
	for {
		c.mu.Lock()
		done := !c.running
		c.mu.Unlock()
		if done || time.Now().After(deadline) {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}

	later := sites()
	c.annotate(later)
	if later[0].CertNotAfter == nil || !later[0].CertNotAfter.Equal(expires) {
		t.Fatalf("want expiry %v, got %v", expires, later[0].CertNotAfter)
	}
	if later[0].CertIssuer != "Let's Encrypt" {
		t.Fatalf("issuer %q", later[0].CertIssuer)
	}
	if later[1].CertError == "" || later[1].CertNotAfter != nil {
		t.Fatalf("broken site: error %q, expiry %v", later[1].CertError, later[1].CertNotAfter)
	}
}

func TestFetchLocalCertReadsTheServedCertificate(t *testing.T) {
	srv := httptest.NewTLSServer(nil)
	defer srv.Close()
	u, _ := url.Parse(srv.URL)
	_, port, _ := net.SplitHostPort(u.Host)

	cert, err := fetchLocalCert("example.com", port)
	if err != nil {
		t.Fatal(err)
	}
	if !cert.NotAfter.Equal(srv.Certificate().NotAfter) {
		t.Fatalf("got %v, want %v", cert.NotAfter, srv.Certificate().NotAfter)
	}
}

package main

import (
	"crypto/tls"
	"crypto/x509"
	"net"
	"strings"
	"sync"
	"time"

	"beacle/shared"
)

// certChecker reads the certificate each proxied domain is actually served
// with, so the panel can warn while a failed renewal is still weeks from
// taking the site down.
//
// It asks the proxy on this machine (127.0.0.1, with the domain as SNI)
// instead of going out to the internet: that sees exactly what the proxy has
// loaded, works for domains only resolvable inside a tailnet, and needs no
// DNS. A CDN in front of the server has its own certificate, which is the
// CDN's business.
//
// Checks run in the background; State() only reads the cache, so a slow or
// hung handshake never holds up the proxy report.
type certChecker struct {
	mu      sync.Mutex
	results map[string]certResult // by host:port
	running bool

	// fetch is swapped out in tests.
	fetch func(host, port string) (*x509.Certificate, error)
}

type certResult struct {
	at       time.Time
	notAfter time.Time
	issuer   string
	err      string
}

const (
	// Certificates change rarely; a renewal shows up within this.
	certRecheck = 6 * time.Hour
	// A failed check is retried sooner: the proxy may just have been
	// restarting, or still be obtaining the certificate.
	certRetry   = 30 * time.Minute
	certTimeout = 5 * time.Second
)

func newCertChecker() *certChecker {
	return &certChecker{results: map[string]certResult{}, fetch: fetchLocalCert}
}

func fetchLocalCert(host, port string) (*x509.Certificate, error) {
	d := &net.Dialer{Timeout: certTimeout}
	conn, err := tls.DialWithDialer(d, "tcp", net.JoinHostPort("127.0.0.1", port), &tls.Config{
		ServerName: host,
		// Only the dates are read. Verifying against the system roots would
		// turn an expired certificate — the case this is for — into an error
		// with no date in it.
		InsecureSkipVerify: true, //nolint:gosec
	})
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	certs := conn.ConnectionState().PeerCertificates
	if len(certs) == 0 {
		return nil, errNoCert
	}
	return certs[0], nil
}

type certError string

func (e certError) Error() string { return string(e) }

const errNoCert = certError("no certificate presented")

// certTarget turns a site address into the host to ask for and the port the
// proxy serves it on. ok is false for addresses with no public certificate to
// watch: plain HTTP, wildcards (nothing to put in SNI), IP addresses and
// localhost.
func certTarget(site shared.ProxySite) (host, port string, ok bool) {
	if site.SSL == shared.SSLDisabled || site.TLSMode == "none" || site.TLSMode == "internal" {
		return "", "", false
	}
	addr := site.Domain
	if strings.HasPrefix(addr, "http://") {
		return "", "", false
	}
	addr = strings.TrimPrefix(addr, "https://")
	if i := strings.IndexByte(addr, '/'); i >= 0 {
		addr = addr[:i]
	}
	host, port = addr, "443"
	if h, p, err := net.SplitHostPort(addr); err == nil {
		host, port = h, p
	}
	if port == "80" || host == "" || host == "localhost" || strings.Contains(host, "*") || net.ParseIP(host) != nil {
		return "", "", false
	}
	return strings.ToLower(host), port, true
}

// annotate fills the certificate fields from what is known and starts a
// background round for anything missing or stale.
func (c *certChecker) annotate(sites []shared.ProxySite) {
	now := time.Now()
	c.mu.Lock()
	defer c.mu.Unlock()

	var due [][2]string
	for i := range sites {
		host, port, ok := certTarget(sites[i])
		if !ok {
			continue
		}
		key := net.JoinHostPort(host, port)
		r, seen := c.results[key]
		if !seen || now.Sub(r.at) > r.maxAge() {
			due = append(due, [2]string{host, port})
		}
		if !seen {
			continue
		}
		if r.err != "" {
			sites[i].CertError = r.err
			continue
		}
		at := r.notAfter
		sites[i].CertNotAfter = &at
		sites[i].CertIssuer = r.issuer
	}
	if len(due) > 0 && !c.running {
		c.running = true
		go c.check(due)
	}
}

func (r certResult) maxAge() time.Duration {
	if r.err != "" {
		return certRetry
	}
	return certRecheck
}

func (c *certChecker) check(targets [][2]string) {
	for _, t := range targets {
		r := certResult{at: time.Now()}
		cert, err := c.fetch(t[0], t[1])
		if err != nil {
			r.err = err.Error()
		} else {
			r.notAfter = cert.NotAfter.UTC()
			r.issuer = cert.Issuer.CommonName
			if len(cert.Issuer.Organization) > 0 {
				r.issuer = cert.Issuer.Organization[0]
			}
		}
		c.mu.Lock()
		c.results[net.JoinHostPort(t[0], t[1])] = r
		c.mu.Unlock()
	}
	c.mu.Lock()
	c.running = false
	c.mu.Unlock()
}

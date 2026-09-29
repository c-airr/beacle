package shared

import (
	"strings"
	"testing"
)

func TestWGKeyPublicMatchesKnownVector(t *testing.T) {
	// RFC 7748 section 6.1, Alice.
	priv, err := ParseWGKeyHex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
	if err != nil {
		t.Fatal(err)
	}
	pub, err := priv.PublicKey()
	if err != nil {
		t.Fatal(err)
	}
	if got, want := pub.Hex(), "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"; got != want {
		t.Fatalf("public key %s, want %s", got, want)
	}
}

func TestWGJoinRoundTrip(t *testing.T) {
	priv, _ := GenerateWGPrivateKey()
	peer, _ := GenerateWGPrivateKey()
	peerPub, _ := peer.PublicKey()
	psk, _ := GenerateWGPresharedKey()
	j := WGJoin{
		PrivateKey:    priv.String(),
		PeerPublicKey: peerPub.String(),
		PresharedKey:  psk.String(),
		Address:       "10.87.0.2",
		PeerAddress:   WGBackendTunnelIP,
		ListenPort:    WGDefaultPort,
		VPSID:         "abc",
	}
	tok := j.Encode()
	if !strings.HasPrefix(tok, WGJoinPrefix) || strings.ContainsAny(tok, " +/=") {
		t.Fatalf("token not shell-safe: %q", tok)
	}
	got, err := DecodeWGJoin(tok)
	if err != nil {
		t.Fatal(err)
	}
	if got != j {
		t.Fatalf("round trip mismatch: %+v", got)
	}
	if got.BackendURL() != "http://10.87.0.1:9930" {
		t.Fatalf("backend url %q", got.BackendURL())
	}
}

func TestDecodeWGJoinRejectsGarbage(t *testing.T) {
	for _, s := range []string{"", "bcwg1.", "bcwg1.!!!", "nope", WGJoinPrefix + "e30"} {
		if _, err := DecodeWGJoin(s); err == nil {
			t.Fatalf("accepted %q", s)
		}
	}
}

func TestClassifyIP(t *testing.T) {
	cases := map[string]IPClass{
		"1.2.3.4":         IPPublic,
		"100.64.0.1":      IPCGNAT,
		"100.127.255.254": IPCGNAT,
		"100.128.0.1":     IPPublic,
		"10.0.0.5":        IPPrivate,
		"192.168.1.1":     IPPrivate,
		"172.16.0.1":      IPPrivate,
		"169.254.1.1":     IPPrivate,
		"127.0.0.1":       IPLoopback,
		"2001:db8::1":     IPPublic,
		"fd00::1":         IPPrivate,
		"not-an-ip":       IPInvalid,
	}
	for in, want := range cases {
		if got := ClassifyIP(in); got != want {
			t.Errorf("ClassifyIP(%q) = %s, want %s", in, got, want)
		}
	}
}

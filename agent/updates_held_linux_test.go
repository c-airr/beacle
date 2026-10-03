//go:build linux

package main

import "testing"

func TestAptSimulatedInstalls(t *testing.T) {
	out := `Reading package lists...
Calculating upgrade...
The following packages have been kept back:
  mariadb-client
The following NEW packages will be installed:
  linux-image-5.15.0-130-generic
The following packages will be upgraded:
  linux-generic mariadb-server
Inst linux-image-5.15.0-130-generic (5.15.0-130.140 Ubuntu:22.04/jammy-updates [amd64])
Inst linux-generic [5.15.0.125.123] (5.15.0.130.128 Ubuntu:22.04/jammy-updates [amd64])
Inst mariadb-server [1:11.4.12+maria~ubu2204] (1:11.4.13+maria~ubu2204 mariadb:jammy [amd64])
Conf linux-generic (5.15.0.130.128 Ubuntu:22.04/jammy-updates [amd64])
`
	m := aptSimulatedInstalls(out)
	for _, n := range []string{"linux-generic", "mariadb-server", "linux-image-5.15.0-130-generic"} {
		if !m[n] {
			t.Errorf("%s should be installed", n)
		}
	}
	if m["mariadb-client"] {
		t.Error("kept-back mariadb-client counted as installed")
	}
}

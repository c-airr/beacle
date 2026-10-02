//go:build linux

package main

import (
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// openWireGuardPort lets the tunnel's UDP port through this host's own
// firewall, with whatever the host actually uses:
//
//   - ufw, when it is active;
//   - firewalld, when it is running;
//   - otherwise plain iptables, inserted at the top of INPUT so it lands
//     before a trailing REJECT (Oracle Cloud images ship exactly that, with
//     ufw installed but inactive), and saved if netfilter-persistent exists.
//
// It cannot open a provider's firewall (Oracle security lists, AWS security
// groups, Hetzner Cloud firewall): that lives outside the machine. Returns
// what it did, for the log.
func openWireGuardPort(port int) (string, error) {
	if port <= 0 {
		return "", fmt.Errorf("no WireGuard port configured")
	}
	p := strconv.Itoa(port)
	fwMu.Lock()
	defer fwMu.Unlock()

	if _, err := exec.LookPath("ufw"); err == nil {
		if out, err := runCmd(15*time.Second, "ufw", "status"); err == nil && strings.Contains(out, "Status: active") {
			// ufw skips a rule it already has.
			if out, err := runCmd(30*time.Second, "ufw", "allow", p+"/udp", "comment", "beacle wireguard"); err != nil {
				return "", fmt.Errorf("ufw allow %s/udp: %s", p, firstLine(out))
			}
			return "ufw allow " + p + "/udp", nil
		}
	}
	if _, err := exec.LookPath("firewall-cmd"); err == nil {
		if out, err := runCmd(10*time.Second, "firewall-cmd", "--state"); err == nil && strings.TrimSpace(out) == "running" {
			// Runtime for now, permanent for the next reload or boot.
			for _, args := range [][]string{
				{"--add-port=" + p + "/udp"},
				{"--permanent", "--add-port=" + p + "/udp"},
			} {
				if out, err := runCmd(30*time.Second, "firewall-cmd", args...); err != nil {
					return "", fmt.Errorf("firewall-cmd %s: %s", strings.Join(args, " "), firstLine(out))
				}
			}
			return "firewalld add-port " + p + "/udp", nil
		}
	}
	if _, err := exec.LookPath("iptables"); err == nil {
		rule := []string{"INPUT", "-p", "udp", "-m", "udp", "--dport", p,
			"-m", "comment", "--comment", "beacle wireguard", "-j", "ACCEPT"}
		if _, err := runCmd(10*time.Second, "iptables", append([]string{"-C"}, rule...)...); err == nil {
			return "iptables: already open", nil
		}
		insert := append([]string{"-I", rule[0], "1"}, rule[1:]...)
		if out, err := runCmd(30*time.Second, "iptables", insert...); err != nil {
			return "", fmt.Errorf("iptables: %s", firstLine(out))
		}
		iptablesPersist()
		return "iptables -I INPUT 1 udp/" + p, nil
	}
	if _, err := exec.LookPath("nft"); err == nil {
		return "", fmt.Errorf("nftables without an iptables wrapper: allow udp/%s by hand", p)
	}
	return "no host firewall", nil
}

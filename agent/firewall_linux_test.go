package main

import "testing"

// What `iptables -S INPUT` prints on an Oracle Cloud Ubuntu image.
const oracleInput = `-P INPUT ACCEPT
-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A INPUT -p icmp -j ACCEPT
-A INPUT -i lo -j ACCEPT
-A INPUT -p udp -m udp --sport 123 -j ACCEPT
-A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT
-A INPUT -j REJECT --reject-with icmp-host-prohibited`

func TestIptablesRulesAreNumberedByPosition(t *testing.T) {
	rules, def := parseIptablesRules(oracleInput)
	if def != "allow" {
		t.Errorf("default incoming = %q, want allow (the policy line)", def)
	}
	if len(rules) != 6 {
		t.Fatalf("want 6 rules, got %d", len(rules))
	}
	ssh := rules[4]
	if ssh.ID != "5" || ssh.Proto != "tcp" || ssh.Port != "22" || ssh.Action != "allow" {
		t.Errorf("ssh rule = %+v", ssh)
	}
	if last := rules[5]; last.ID != "6" || last.Action != "deny" {
		t.Errorf("trailing REJECT = %+v", last)
	}
}

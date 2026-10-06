package main

import (
	"net"
	"sync"
	"time"

	"beacle/shared"
)

// internetTargets are dialled to answer "does this computer have internet".
// Plain IPs, so a dead DNS resolver does not read as a dead line, and two
// operators, so one of them having a bad day does not either.
var internetTargets = []string{"1.1.1.1:443", "8.8.8.8:443", "8.8.8.8:53"}

const internetDialTimeout = 2 * time.Second

// internetUp dials every target at once and takes the first answer. A
// network that lets none of them through still gets a ping to 8.8.8.8, which
// some locked-down networks allow when they block outbound TCP.
func internetUp() bool {
	ok := make(chan bool, len(internetTargets))
	for _, t := range internetTargets {
		go func(addr string) {
			c, err := net.DialTimeout("tcp", addr, internetDialTimeout)
			if err == nil {
				_ = c.Close()
			}
			ok <- err == nil
		}(t)
	}
	for range internetTargets {
		if <-ok {
			return true
		}
	}
	up, _ := icmpPing("8.8.8.8")
	return up
}

// LocalNet tracks whether this computer itself is online. Every server
// dropping off at once is far more often the laptop lid, the Wi-Fi or an
// unplugged cable than a fleet-wide outage, and the panel should say which.
type LocalNet struct {
	mu      sync.Mutex
	online  bool
	since   time.Time
	checked time.Time
	probe   func() bool
	// onChange runs on every flip, outside the lock.
	onChange func(shared.LocalNetStatus)
}

func NewLocalNet() *LocalNet {
	return &LocalNet{online: true, since: time.Now().UTC(), probe: internetUp}
}

func (n *LocalNet) Status() shared.LocalNetStatus {
	n.mu.Lock()
	defer n.mu.Unlock()
	return shared.LocalNetStatus{Online: n.online, Since: n.since}
}

func (n *LocalNet) Online() bool {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.online
}

// Up reports whether the line is up, reusing a good answer younger than
// maxAge. A bad one is never reused: the point of asking again is to notice
// the moment it comes back.
func (n *LocalNet) Up(maxAge time.Duration) bool {
	n.mu.Lock()
	fresh := n.online && time.Since(n.checked) < maxAge
	n.mu.Unlock()
	if fresh {
		return true
	}
	return n.Check()
}

// Check probes the line now and reports whether it is up. It blocks for up
// to a few seconds when the line is down, so it belongs on the offline sweep,
// never on a request path.
func (n *LocalNet) Check() bool {
	up := n.probe()
	n.mu.Lock()
	n.checked = time.Now()
	changed := up != n.online
	if changed {
		n.online = up
		n.since = time.Now().UTC()
	}
	st := shared.LocalNetStatus{Online: n.online, Since: n.since}
	cb := n.onChange
	n.mu.Unlock()
	if changed && cb != nil {
		cb(st)
	}
	return up
}

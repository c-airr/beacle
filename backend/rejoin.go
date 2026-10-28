package main

import (
	"net/http"
	"slices"
	"sync"
	"time"

	"beacle/shared"
)

// An agent holding credentials the registry no longer knows (state.json
// reset, restored backup, reinstalled panel) is most likely one of the
// user's servers — but anyone on the tailnet can present a made-up ID and
// token, and an adopted server is a watcher candidate that gets the webhook
// URLs. So it is not let in on its word: it waits here, and the person at
// the panel lets it back in or turns it away. The agent retries every 30 s,
// which keeps its request fresh and connects it once approved.

const (
	rejoinMax = 64
	// A request the agent stopped renewing (it went away, or got
	// credentials some other way) drops out of the list.
	rejoinTTL = 3 * time.Minute
)

// rejoinRequest is one waiting agent. Only IP and TailnetName are verified
// facts — the socket's address and the name Tailscale gives it; the rest is
// what the agent says about itself.
type rejoinRequest struct {
	IP           string    `json:"ip"`
	TailnetName  string    `json:"tailnet_name,omitempty"`
	VPSID        string    `json:"vps_id,omitempty"`
	Hostname     string    `json:"hostname,omitempty"`
	AgentVersion string    `json:"agent_version,omitempty"`
	FirstSeen    time.Time `json:"first_seen"`
	LastSeen     time.Time `json:"last_seen"`

	token string
}

// rejoinQueue holds one request per address: a machine on the tailnet can
// replace its own request, not crowd out another server's. The zero value
// is ready to use.
type rejoinQueue struct {
	mu      sync.Mutex
	pending map[string]*rejoinRequest
	// Turned away while the panel runs; the agent keeps knocking and would
	// otherwise be back on the list half a minute later.
	refused map[string]bool
}

// knock records a request and reports whether the list changed shape (a
// new entry), which is when the app needs telling.
func (q *rejoinQueue) knock(req rejoinRequest, token string) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.refused[req.IP] {
		return false
	}
	if q.pending == nil {
		q.pending = map[string]*rejoinRequest{}
	}
	now := time.Now()
	q.expireLocked(now)
	req.token, req.LastSeen = token, now
	if old := q.pending[req.IP]; old != nil {
		req.FirstSeen = old.FirstSeen
		changed := old.VPSID != req.VPSID || old.Hostname != req.Hostname
		q.pending[req.IP] = &req
		return changed
	}
	if len(q.pending) >= rejoinMax {
		return false
	}
	req.FirstSeen = now
	q.pending[req.IP] = &req
	return true
}

func (q *rejoinQueue) expireLocked(now time.Time) {
	for ip, r := range q.pending {
		if now.Sub(r.LastSeen) > rejoinTTL {
			delete(q.pending, ip)
		}
	}
}

func (q *rejoinQueue) list() []rejoinRequest {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.expireLocked(time.Now())
	out := []rejoinRequest{}
	for _, r := range q.pending {
		out = append(out, *r)
	}
	slices.SortFunc(out, func(a, b rejoinRequest) int { return a.FirstSeen.Compare(b.FirstSeen) })
	return out
}

// take removes and returns the request from ip.
func (q *rejoinQueue) take(ip string) *rejoinRequest {
	q.mu.Lock()
	defer q.mu.Unlock()
	r := q.pending[ip]
	delete(q.pending, ip)
	return r
}

func (q *rejoinQueue) refuse(ip string) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	_, was := q.pending[ip]
	delete(q.pending, ip)
	if q.refused == nil {
		q.refused = map[string]bool{}
	}
	q.refused[ip] = true
	return was
}

func (s *Server) broadcastRejoin() {
	if s.hub != nil {
		s.hub.Broadcast(shared.WSRejoin, s.rejoins.list())
	}
}

func (s *Server) handleListRejoin(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.rejoins.list())
}

// handleApproveRejoin lets a waiting agent back in under the ID and token it
// already holds; its next retry connects.
func (s *Server) handleApproveRejoin(w http.ResponseWriter, r *http.Request) {
	req := s.rejoins.take(r.PathValue("ip"))
	if req == nil {
		writeErr(w, http.StatusNotFound, "no such request — the server may have stopped asking")
		return
	}
	defer s.broadcastRejoin()
	if req.VPSID != "" && s.store.GetVPS(req.VPSID) != nil {
		writeErr(w, http.StatusConflict, "a server with this ID is already in the panel")
		return
	}
	name := req.TailnetName
	if name == "" {
		name = req.Hostname
	}
	entry := s.store.AdoptVPS(req.VPSID, req.token, req.Hostname, req.IP, name, req.AgentVersion)
	// Pending until its agent actually connects: no offline alert for the
	// half minute until it retries.
	entry = s.store.UpdateVPS(entry.VPS.ID, func(e *VPSEntry) { e.VPS.Status = shared.VPSPending })
	s.logAction(entry.VPS, "vps_adopt", "Agent let back in from "+req.IP, true)
	if s.hub != nil {
		s.hub.Broadcast(shared.WSVPSList, s.store.ListVPS())
	}
	writeJSON(w, http.StatusOK, entry.VPS)
}

func (s *Server) handleRefuseRejoin(w http.ResponseWriter, r *http.Request) {
	if !s.rejoins.refuse(r.PathValue("ip")) {
		writeErr(w, http.StatusNotFound, "no such request")
		return
	}
	s.broadcastRejoin()
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

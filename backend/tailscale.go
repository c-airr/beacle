package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os/exec"
	"strings"
)

// TailscaleDevice is one node visible in the local tailnet.
type TailscaleDevice struct {
	Name string   `json:"name"`
	DNS  string   `json:"dns"`
	IPs  []string `json:"ips"`
	OS   string   `json:"os"`
	Online bool   `json:"online"`
	Self   bool   `json:"self"`
}

type tsStatusJSON struct {
	Self struct {
		HostName     string   `json:"HostName"`
		DNSName      string   `json:"DNSName"`
		TailscaleIPs []string `json:"TailscaleIPs"`
		OS           string   `json:"OS"`
		Online       bool     `json:"Online"`
	} `json:"Self"`
	Peer map[string]struct {
		HostName     string   `json:"HostName"`
		DNSName      string   `json:"DNSName"`
		TailscaleIPs []string `json:"TailscaleIPs"`
		OS           string   `json:"OS"`
		Online       bool     `json:"Online"`
	} `json:"Peer"`
}

func tailscaleStatus() ([]TailscaleDevice, error) {
	out, err := exec.Command("tailscale", "status", "--json").Output()
	if err != nil {
		return nil, fmt.Errorf("tailscale not available: %w", err)
	}
	var st tsStatusJSON
	if err := json.Unmarshal(out, &st); err != nil {
		return nil, err
	}
	var devices []TailscaleDevice
	if st.Self.HostName != "" || len(st.Self.TailscaleIPs) > 0 {
		devices = append(devices, TailscaleDevice{
			Name:   st.Self.HostName,
			DNS:    strings.TrimSuffix(st.Self.DNSName, "."),
			IPs:    st.Self.TailscaleIPs,
			OS:     st.Self.OS,
			Online: st.Self.Online,
			Self:   true,
		})
	}
	for _, p := range st.Peer {
		devices = append(devices, TailscaleDevice{
			Name:   p.HostName,
			DNS:    strings.TrimSuffix(p.DNSName, "."),
			IPs:    p.TailscaleIPs,
			OS:     p.OS,
			Online: p.Online,
		})
	}
	return devices, nil
}

func tailscaleSelfIPv4() string {
	out, err := exec.Command("tailscale", "ip", "-4").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func (s *Server) handleTailscaleDevices(w http.ResponseWriter, r *http.Request) {
	devs, err := tailscaleStatus()
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, devs)
}

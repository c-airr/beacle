package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"strings"
	"time"
)

type geoResult struct {
	Lat      float64
	Lon      float64
	Location string
}

// lookupGeoIP resolves approximate lat/lon + city label for a public IP.
// Uses ip-api.com (no API key; HTTP free tier).
func lookupGeoIP(ip string) (geoResult, error) {
	ip = strings.TrimSpace(ip)
	if ip == "" {
		return geoResult{}, fmt.Errorf("empty ip")
	}
	parsed := net.ParseIP(ip)
	if parsed == nil {
		return geoResult{}, fmt.Errorf("invalid ip %q", ip)
	}
	if parsed.IsLoopback() || parsed.IsPrivate() || parsed.IsLinkLocalUnicast() || parsed.IsUnspecified() {
		return geoResult{}, fmt.Errorf("non-public ip %s", ip)
	}
	// Tailscale CGNAT — not useful for world map placement.
	if isTailscaleIP(parsed) {
		return geoResult{}, fmt.Errorf("tailscale ip %s", ip)
	}

	client := &http.Client{Timeout: 4 * time.Second}
	url := fmt.Sprintf("http://ip-api.com/json/%s?fields=status,message,country,regionName,city,lat,lon,query", ip)
	resp, err := client.Get(url)
	if err != nil {
		return geoResult{}, err
	}
	defer resp.Body.Close()

	var body struct {
		Status     string  `json:"status"`
		Message    string  `json:"message"`
		Country    string  `json:"country"`
		RegionName string  `json:"regionName"`
		City       string  `json:"city"`
		Lat        float64 `json:"lat"`
		Lon        float64 `json:"lon"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return geoResult{}, err
	}
	if body.Status != "success" {
		if body.Message != "" {
			return geoResult{}, fmt.Errorf("geoip: %s", body.Message)
		}
		return geoResult{}, fmt.Errorf("geoip failed for %s", ip)
	}

	loc := body.City
	if loc == "" {
		loc = body.RegionName
	}
	if body.Country != "" {
		if loc != "" {
			loc = loc + ", " + body.Country
		} else {
			loc = body.Country
		}
	}
	return geoResult{Lat: body.Lat, Lon: body.Lon, Location: loc}, nil
}

func isTailscaleIP(ip net.IP) bool {
	ip4 := ip.To4()
	if ip4 == nil {
		return false
	}
	// 100.64.0.0/10
	return ip4[0] == 100 && ip4[1] >= 64 && ip4[1] <= 127
}

// applyPublicIPGeo updates PublicIP and map coordinates when the egress IP changes
// or coordinates are still unset.
func applyPublicIPGeo(e *VPSEntry, publicIP string) {
	publicIP = strings.TrimSpace(publicIP)
	if publicIP == "" {
		return
	}
	needGeo := e.VPS.PublicIP != publicIP || (e.VPS.Latitude == 0 && e.VPS.Longitude == 0)
	e.VPS.PublicIP = publicIP
	if !needGeo {
		return
	}
	geo, err := lookupGeoIP(publicIP)
	if err != nil {
		log.Printf("geoip %s: %v", publicIP, err)
		return
	}
	e.VPS.Latitude = geo.Lat
	e.VPS.Longitude = geo.Lon
	if geo.Location != "" {
		e.VPS.Location = geo.Location
	}
	log.Printf("geoip %s → %.4f,%.4f (%s)", publicIP, geo.Lat, geo.Lon, geo.Location)
}

package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestPanelAPIRefusesWebPages(t *testing.T) {
	h := rejectBrowsers(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	cases := []struct {
		name    string
		headers map[string]string
		want    int
	}{
		{"desktop app (dart:io)", nil, http.StatusOK},
		{"curl", map[string]string{"User-Agent": "curl/8.0"}, http.StatusOK},
		{"cross-site fetch", map[string]string{"Origin": "https://evil.example"}, http.StatusForbidden},
		{"localhost page", map[string]string{"Origin": "http://localhost:3000"}, http.StatusForbidden},
		{"no-cors image", map[string]string{"Sec-Fetch-Site": "cross-site"}, http.StatusForbidden},
		{"typed into the address bar", map[string]string{"Sec-Fetch-Site": "none"}, http.StatusOK},
	}
	for _, c := range cases {
		req := httptest.NewRequest(http.MethodPost, "/api/vps/x/agent/system/reboot", nil)
		for k, v := range c.headers {
			req.Header.Set(k, v)
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != c.want {
			t.Errorf("%s: got %d, want %d", c.name, rec.Code, c.want)
		}
		if rec.Header().Get("Access-Control-Allow-Origin") != "" {
			t.Errorf("%s: must not advertise CORS", c.name)
		}
	}
}

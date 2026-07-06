package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"

	"beacle/shared"
)

// APIServer is the HTTP interface the backend uses to command this agent.
type APIServer struct {
	cfg   *Config
	col   Collector
	proxy *ProxyManager
	upd   *Updater
}

func jsonOut(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func jsonErr(w http.ResponseWriter, code int, msg string) {
	jsonOut(w, code, shared.APIError{Error: msg})
}

// auth enforces the shared bearer token on every request.
func (s *APIServer) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		h := r.Header.Get("Authorization")
		if !strings.HasPrefix(h, "Bearer ") || strings.TrimPrefix(h, "Bearer ") != s.cfg.Token {
			jsonErr(w, http.StatusUnauthorized, "invalid token")
			return
		}
		next(w, r)
	}
}

func (s *APIServer) Routes() http.Handler {
	mux := http.NewServeMux()
	a := s.auth

	mux.HandleFunc("GET /api/health", func(w http.ResponseWriter, r *http.Request) {
		jsonOut(w, 200, map[string]any{"ok": true, "version": AgentVersion})
	})

	// system
	mux.HandleFunc("GET /api/system", a(func(w http.ResponseWriter, r *http.Request) {
		m, err := s.col.Metrics()
		if err != nil {
			jsonErr(w, 500, err.Error())
			return
		}
		jsonOut(w, 200, m)
	}))
	mux.HandleFunc("GET /api/system/processes", a(func(w http.ResponseWriter, r *http.Request) {
		p, err := s.col.Processes()
		if err != nil {
			jsonErr(w, 500, err.Error())
			return
		}
		jsonOut(w, 200, p)
	}))
	mux.HandleFunc("GET /api/system/ports", a(func(w http.ResponseWriter, r *http.Request) {
		p, err := s.col.Ports()
		if err != nil {
			jsonErr(w, 500, err.Error())
			return
		}
		jsonOut(w, 200, p)
	}))
	mux.HandleFunc("GET /api/system/ports/{port}", a(func(w http.ResponseWriter, r *http.Request) {
		port, err := strconv.Atoi(r.PathValue("port"))
		if err != nil {
			jsonErr(w, 400, "bad port")
			return
		}
		p, err := s.col.PortDetail(port)
		if err != nil {
			jsonErr(w, 500, err.Error())
			return
		}
		jsonOut(w, 200, p)
	}))

	// docker
	mux.HandleFunc("GET /api/docker/containers", a(func(w http.ResponseWriter, r *http.Request) {
		jsonOut(w, 200, s.col.Docker().Containers)
	}))
	mux.HandleFunc("GET /api/docker", a(func(w http.ResponseWriter, r *http.Request) {
		jsonOut(w, 200, s.col.Docker())
	}))
	mux.HandleFunc("POST /api/docker/containers/{id}/{action}", a(func(w http.ResponseWriter, r *http.Request) {
		if err := s.col.DockerAction(r.PathValue("id"), r.PathValue("action")); err != nil {
			jsonErr(w, 500, err.Error())
			return
		}
		jsonOut(w, 200, map[string]any{"ok": true})
	}))
	mux.HandleFunc("GET /api/docker/containers/{id}/logs", a(func(w http.ResponseWriter, r *http.Request) {
		tail, _ := strconv.Atoi(r.URL.Query().Get("tail"))
		logs, err := s.col.DockerLogs(r.PathValue("id"), tail)
		if err != nil {
			jsonErr(w, 500, err.Error())
			return
		}
		jsonOut(w, 200, map[string]string{"logs": logs})
	}))
	mux.HandleFunc("GET /api/docker/containers/{id}/stats", a(func(w http.ResponseWriter, r *http.Request) {
		st, err := s.col.DockerStats(r.PathValue("id"))
		if err != nil {
			jsonErr(w, 500, err.Error())
			return
		}
		jsonOut(w, 200, st)
	}))
	mux.HandleFunc("GET /api/docker/images", a(func(w http.ResponseWriter, r *http.Request) {
		jsonOut(w, 200, s.col.Docker().Images)
	}))
	mux.HandleFunc("GET /api/docker/compose", a(func(w http.ResponseWriter, r *http.Request) {
		jsonOut(w, 200, s.col.Docker().Compose)
	}))

	// services
	mux.HandleFunc("GET /api/services/systemd", a(func(w http.ResponseWriter, r *http.Request) {
		u, err := s.col.SystemdUnits()
		if err != nil {
			jsonErr(w, 500, err.Error())
			return
		}
		jsonOut(w, 200, u)
	}))
	mux.HandleFunc("POST /api/services/systemd/{unit}/{action}", a(func(w http.ResponseWriter, r *http.Request) {
		out, err := s.col.SystemdAction(r.PathValue("unit"), r.PathValue("action"))
		if err != nil {
			jsonErr(w, 500, err.Error())
			return
		}
		jsonOut(w, 200, map[string]any{"ok": true, "state": out})
	}))
	mux.HandleFunc("GET /api/services/systemd/{unit}/logs", a(func(w http.ResponseWriter, r *http.Request) {
		lines, _ := strconv.Atoi(r.URL.Query().Get("lines"))
		logs, err := s.col.SystemdLogs(r.PathValue("unit"), lines)
		if err != nil {
			jsonErr(w, 500, err.Error())
			return
		}
		jsonOut(w, 200, map[string]string{"logs": logs})
	}))
	mux.HandleFunc("GET /api/services/screen", a(func(w http.ResponseWriter, r *http.Request) {
		sess, err := s.col.ScreenSessions()
		if err != nil {
			jsonErr(w, 500, err.Error())
			return
		}
		jsonOut(w, 200, sess)
	}))

	// reverse proxy
	mux.HandleFunc("GET /api/proxy", a(func(w http.ResponseWriter, r *http.Request) {
		jsonOut(w, 200, s.proxy.State())
	}))
	mux.HandleFunc("POST /api/proxy/sites", a(func(w http.ResponseWriter, r *http.Request) {
		var req shared.ProxySiteRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Domain == "" || req.Upstream == "" {
			jsonErr(w, 400, "domain and upstream are required")
			return
		}
		site, err := s.proxy.AddSite(req)
		if err != nil {
			jsonErr(w, 500, err.Error())
			return
		}
		jsonOut(w, 200, site)
	}))
	mux.HandleFunc("PUT /api/proxy/sites/{id}", a(func(w http.ResponseWriter, r *http.Request) {
		var req shared.ProxySiteRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			jsonErr(w, 400, "bad json")
			return
		}
		site, err := s.proxy.UpdateSite(r.PathValue("id"), req)
		if err != nil {
			jsonErr(w, 500, err.Error())
			return
		}
		jsonOut(w, 200, site)
	}))
	mux.HandleFunc("DELETE /api/proxy/sites/{id}", a(func(w http.ResponseWriter, r *http.Request) {
		if err := s.proxy.DeleteSite(r.PathValue("id")); err != nil {
			jsonErr(w, 500, err.Error())
			return
		}
		jsonOut(w, 200, map[string]any{"ok": true})
	}))
	mux.HandleFunc("POST /api/proxy/reload", a(func(w http.ResponseWriter, r *http.Request) {
		if err := s.proxy.Reload(); err != nil {
			jsonErr(w, 500, err.Error())
			return
		}
		jsonOut(w, 200, map[string]any{"ok": true})
	}))
	mux.HandleFunc("POST /api/proxy/validate", a(func(w http.ResponseWriter, r *http.Request) {
		jsonOut(w, 200, s.proxy.Validate())
	}))

	// ping (map links)
	mux.HandleFunc("GET /api/ping", a(func(w http.ResponseWriter, r *http.Request) {
		target := r.URL.Query().Get("target")
		if target == "" {
			jsonErr(w, 400, "target required")
			return
		}
		jsonOut(w, 200, s.col.Ping(target))
	}))

	// update / rollback
	mux.HandleFunc("POST /api/update", a(func(w http.ResponseWriter, r *http.Request) {
		msg, err := s.upd.Update()
		if err != nil {
			jsonErr(w, 500, err.Error())
			return
		}
		jsonOut(w, 200, map[string]string{"result": msg})
	}))
	mux.HandleFunc("POST /api/rollback", a(func(w http.ResponseWriter, r *http.Request) {
		msg, err := s.upd.Rollback()
		if err != nil {
			jsonErr(w, 500, err.Error())
			return
		}
		jsonOut(w, 200, map[string]string{"result": msg})
	}))

	return mux
}

// Dispatch executes an agent API route locally (used by the outbound WebSocket
// tunnel). The backend never connects to the agent; commands arrive over WS.
func (s *APIServer) Dispatch(method, pathWithQuery string, body []byte) (int, []byte) {
	u, err := url.Parse(pathWithQuery)
	if err != nil {
		b, _ := json.Marshal(shared.APIError{Error: "bad path"})
		return http.StatusBadRequest, b
	}
	var bodyReader *bytes.Reader
	if len(body) > 0 {
		bodyReader = bytes.NewReader(body)
	}
	req := httptest.NewRequest(method, u.Path, bodyReader)
	if u.RawQuery != "" {
		req.URL.RawQuery = u.RawQuery
	}
	req.Header.Set("Authorization", "Bearer "+s.cfg.Token)
	rec := httptest.NewRecorder()
	s.Routes().ServeHTTP(rec, req)
	return rec.Code, rec.Body.Bytes()
}

package main

import (
	"encoding/json"
	"net/http"
)

type pluginPathReq struct {
	Path string `json:"path"`
}

func decodePath(w http.ResponseWriter, r *http.Request) (string, bool) {
	var req pluginPathReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Path == "" {
		writeErr(w, http.StatusBadRequest, "path required")
		return "", false
	}
	return req.Path, true
}

func (s *Server) handleListPlugins(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.plugins.List())
}

func (s *Server) handleInspectPlugin(w http.ResponseWriter, r *http.Request) {
	path, ok := decodePath(w, r)
	if !ok {
		return
	}
	info, err := s.plugins.Inspect(path)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, info)
}

func (s *Server) handleInstallPlugin(w http.ResponseWriter, r *http.Request) {
	path, ok := decodePath(w, r)
	if !ok {
		return
	}
	bp, err := s.plugins.Install(path)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": bp.manifest.ID, "version": bp.manifest.Version})
}

func (s *Server) handlePatchPlugin(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Enabled    *bool     `json:"enabled"`
		DisabledOn *[]string `json:"disabled_on"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad json")
		return
	}
	if err := s.plugins.SetState(r.PathValue("id"), req.Enabled, req.DisabledOn); err != nil {
		writeErr(w, http.StatusNotFound, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) handleDeletePlugin(w http.ResponseWriter, r *http.Request) {
	if err := s.plugins.Remove(r.PathValue("id")); err != nil {
		writeErr(w, http.StatusNotFound, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) handlePluginLog(w http.ResponseWriter, r *http.Request) {
	lines, ok := s.plugins.Logs(r.PathValue("id"))
	if !ok {
		writeErr(w, http.StatusNotFound, "no such plugin")
		return
	}
	writeJSON(w, http.StatusOK, lines)
}

// handlePluginUI renders one slot: ?slot=server.section&server=<id>, or
// ?slot=nav.tab&tab=<id>.
func (s *Server) handlePluginUI(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	writeJSON(w, http.StatusOK, s.plugins.Render(q.Get("slot"), q.Get("server"), q.Get("tab")))
}

func (s *Server) handlePluginAction(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Action string         `json:"action"`
		Args   map[string]any `json:"args"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Action == "" {
		writeErr(w, http.StatusBadRequest, "action required")
		return
	}
	res, err := s.plugins.Action(r.PathValue("id"), req.Action, req.Args)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"result": res})
}

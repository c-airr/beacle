package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
)

// A package arrives as the .zip itself (the app reads the file it picked,
// which a sandboxed app may not be able to hand on as a path), as a folder
// path, which installs it linked, or as an id in the plugin catalog.
type pluginSrcReq struct {
	Path    string `json:"path"`
	Zip     []byte `json:"zip"` // base64 in JSON
	Catalog string `json:"catalog"`
	Ref     string `json:"ref"` // the app's commit or version, for the catalog
}

const pluginZipMax = 8 << 20

// readSource reads the package a request names. linked is the folder it
// stays linked to, or "".
func readSource(w http.ResponseWriter, r *http.Request) (files map[string]string, linked string, ok bool) {
	var req pluginSrcReq
	err := json.NewDecoder(http.MaxBytesReader(w, r.Body, pluginZipMax*2)).Decode(&req)
	given := 0
	for _, set := range []bool{req.Path != "", len(req.Zip) > 0, req.Catalog != ""} {
		if set {
			given++
		}
	}
	if err != nil || given != 1 {
		writeErr(w, http.StatusBadRequest, "path, zip or catalog required")
		return nil, "", false
	}
	switch {
	case req.Catalog != "":
		files, err = catalogSource(req.Catalog, req.Ref)
		if err != nil {
			writeErr(w, http.StatusBadGateway, err.Error())
			return nil, "", false
		}
		return files, "", true
	case req.Path != "":
		files, err = readPackage(req.Path)
		if err == nil {
			if st, serr := os.Stat(req.Path); serr == nil && st.IsDir() {
				linked, _ = filepath.Abs(req.Path)
			}
		}
	default:
		var f *os.File
		if f, err = os.CreateTemp("", "beacle-plugin-*.zip"); err == nil {
			_, err = f.Write(req.Zip)
			f.Close()
			if err == nil {
				files, err = readPackage(f.Name())
			}
			os.Remove(f.Name())
		}
	}
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return nil, "", false
	}
	return files, linked, true
}

func (s *Server) handleListPlugins(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.plugins.List())
}

func (s *Server) handlePluginCatalog(w http.ResponseWriter, r *http.Request) {
	out, err := s.plugins.Catalog(r.URL.Query().Get("ref"), r.URL.Query().Get("version"))
	if err != nil {
		writeErr(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleInspectPlugin(w http.ResponseWriter, r *http.Request) {
	files, _, ok := readSource(w, r)
	if !ok {
		return
	}
	info, err := s.plugins.InspectFiles(files)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, info)
}

func (s *Server) handleInstallPlugin(w http.ResponseWriter, r *http.Request) {
	files, linked, ok := readSource(w, r)
	if !ok {
		return
	}
	bp, err := s.plugins.InstallFiles(files, linked)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": bp.manifest.ID, "version": bp.manifest.Version, "setup": bp.hasSetup()})
}

func (s *Server) handlePatchPlugin(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Enabled    *bool          `json:"enabled"`
		DisabledOn *[]string      `json:"disabled_on"`
		Config     map[string]any `json:"config"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad json")
		return
	}
	if err := s.plugins.SetState(r.PathValue("id"), req.Enabled, req.DisabledOn, req.Config); err != nil {
		code := http.StatusBadRequest
		if errors.Is(err, errNoPlugin) {
			code = http.StatusNotFound
		}
		writeErr(w, code, err.Error())
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

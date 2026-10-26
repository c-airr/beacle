package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"

	"beacle/shared/plugin"
)

// The marketplace: plugins/index.json of this repository and the packages
// it lists, fetched from GitHub at the commit (or tag) the app was built
// from — the code reviewed with that release, not whatever main holds
// today. A dev build has neither in the repository and falls back to main.
// Installing goes through the same review as a .zip.

// catalogBase is where the repository's files are served; a seam for tests.
var catalogBase = "https://raw.githubusercontent.com/c-airr/beacle"

var (
	catalogRefRe  = regexp.MustCompile(`^[0-9A-Za-z._-]{1,64}$`)
	catalogPathRe = regexp.MustCompile(`^[a-z0-9_-]+(/[a-z0-9_-]+)*$`)
	catalogHTTP   = &http.Client{Timeout: 15 * time.Second}
)

const catalogIndexMax = 256 << 10

// catalogEntry is one plugin in plugins/index.json. Path is its folder,
// relative to plugins/.
type catalogEntry struct {
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	Description string   `json:"description"`
	Version     string   `json:"version"`
	Path        string   `json:"path"`
	MinBeacle   string   `json:"min_beacle,omitempty"`
	Tags        []string `json:"tags,omitempty"`
}

type catalogIndex struct {
	Plugins []catalogEntry `json:"plugins"`
}

var errCatalogMissing = errors.New("not in the repository")

func fetchCatalogFile(ref, name string, limit int64) ([]byte, error) {
	resp, err := catalogHTTP.Get(catalogBase + "/" + ref + "/plugins/" + name)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return nil, errCatalogMissing
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s: HTTP %d", name, resp.StatusCode)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > limit {
		return nil, fmt.Errorf("%s is too large", name)
	}
	return b, nil
}

// catalog reads the index at ref (main when ref is blank or has no index)
// and returns the ref it came from.
func catalog(ref string) (catalogIndex, string, error) {
	if ref == "" {
		ref = "main"
	}
	if !catalogRefRe.MatchString(ref) {
		return catalogIndex{}, "", errors.New("bad ref")
	}
	raw, err := fetchCatalogFile(ref, "index.json", catalogIndexMax)
	if errors.Is(err, errCatalogMissing) && ref != "main" {
		ref = "main"
		raw, err = fetchCatalogFile(ref, "index.json", catalogIndexMax)
	}
	if err != nil {
		return catalogIndex{}, "", fmt.Errorf("plugin catalog: %w", err)
	}
	var idx catalogIndex
	if err := json.Unmarshal(raw, &idx); err != nil {
		return catalogIndex{}, "", fmt.Errorf("plugin catalog: %w", err)
	}
	return idx, ref, nil
}

// Catalog is GET /api/plugins/catalog: what can be installed, and what of
// it is installed or has an update. version is the app's, for min_beacle.
func (p *Plugins) Catalog(ref, version string) (map[string]any, error) {
	idx, used, err := catalog(ref)
	if err != nil {
		return nil, err
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	list := []map[string]any{}
	for _, e := range idx.Plugins {
		item := map[string]any{
			"id": e.ID, "name": e.Name, "description": e.Description, "version": e.Version,
			"tags": e.Tags, "min_beacle": e.MinBeacle,
			"compatible": e.MinBeacle == "" || !versionBefore(version, e.MinBeacle),
		}
		if bp := p.list[e.ID]; bp != nil {
			item["installed_version"] = bp.manifest.Version
			item["update"] = versionBefore(bp.manifest.Version, e.Version)
		}
		list = append(list, item)
	}
	return map[string]any{"ref": used, "plugins": list}, nil
}

// CatalogFiles downloads one catalog plugin's package.
func CatalogFiles(ref, id string) (map[string]string, error) {
	idx, used, err := catalog(ref)
	if err != nil {
		return nil, err
	}
	var entry *catalogEntry
	for i := range idx.Plugins {
		if idx.Plugins[i].ID == id {
			entry = &idx.Plugins[i]
		}
	}
	if entry == nil {
		return nil, fmt.Errorf("%q is not in the plugin catalog", id)
	}
	if !catalogPathRe.MatchString(entry.Path) {
		return nil, fmt.Errorf("plugin catalog: bad path %q", entry.Path)
	}
	files := map[string]string{}
	for _, name := range pluginFiles {
		b, err := fetchCatalogFile(used, entry.Path+"/"+name, pluginFileMax)
		if errors.Is(err, errCatalogMissing) {
			continue
		}
		if err != nil {
			return nil, err
		}
		files[name] = string(b)
	}
	m, err := plugin.ParseManifest([]byte(files["manifest.json"]))
	if err != nil {
		return nil, err
	}
	if m.ID != id {
		return nil, fmt.Errorf("plugin catalog: %s/manifest.json is %q, not %q", entry.Path, m.ID, id)
	}
	return files, nil
}

// catalogSource is a request's {"catalog": id, "ref": …}.
func catalogSource(id, ref string) (map[string]string, error) {
	if strings.TrimSpace(id) == "" {
		return nil, errors.New("catalog id required")
	}
	return CatalogFiles(ref, id)
}

package plugin

import (
	"strings"
	"testing"

	lua "github.com/yuin/gopher-lua"
)

// FuzzPackage: a plugin is text from anyone. Neither the manifest parser nor
// the Lua compiler may panic on it — the panel compiles every installed
// plugin at startup, outside any request that would recover.
func FuzzPackage(f *testing.F) {
	f.Add(`{"id":"x","name":"X","version":"1","metrics":{"t_*":{"label":"T"}},"permissions":{"api":["GET /api/vps"]}}`,
		"beacle.every(5, function() beacle.metric('t_a', 1) end)")
	f.Add(`{"id":"a","name":"a","version":"1","config":[{"key":"k","type":"select","options":["1"]}]}`,
		"local t = {} for i=1,3 do t[#t+1]=i end return ui.card{title='x'}")
	f.Fuzz(func(t *testing.T, manifest, src string) {
		if m, err := ParseManifest([]byte(manifest)); err == nil {
			for k := range m.Metrics {
				m.MetricDef(strings.TrimSuffix(k, "*") + "a")
			}
			ConfigValues(m, map[string]any{"k": 1}, true)
		}
		L := lua.NewState(lua.Options{SkipOpenLibs: true})
		defer L.Close()
		_, _ = L.Load(strings.NewReader(src), "fuzz.lua")
	})
}

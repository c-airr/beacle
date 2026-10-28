package plugin

import (
	"runtime"
	"strings"
	"testing"
	"time"
)

// peakHeap runs f and reports the largest heap seen meanwhile.
func peakHeap(t *testing.T, f func()) uint64 {
	t.Helper()
	runtime.GC()
	done := make(chan struct{})
	peak := make(chan uint64)
	go func() {
		var max uint64
		for {
			if in, _ := heap(); in > max {
				max = in
			}
			select {
			case <-done:
				peak <- max
				return
			case <-time.After(time.Millisecond):
			}
		}
	}()
	f()
	close(done)
	return <-peak
}

// A plugin that runs away with memory is stopped and says so, and the
// process stays well clear of the gigabytes it asked for. Each of these
// would otherwise take the agent or the panel down.
func TestRunawayMemoryStopsThePlugin(t *testing.T) {
	for _, c := range []struct {
		name, src string
		stops     bool // caught while running, not refused up front
	}{
		{"doubling", `local s = "x" while true do s = s .. s end`, true},
		{"table", `local t, i = {}, 0 while true do i = i + 1 t[i] = {i} end`, true},
		{"rep", `local s = string.rep("x", 1e12)`, false},
		{"gsub", `local s = string.rep("x", 1e6) s = string.gsub(s, ".", string.rep("y", 1e6))`, false},
		{"concat", `local t = {} for i = 1, 1e5 do t[i] = "x" end local s = table.concat(t, string.rep(",", 1e5))`, false},
		{"rep growth", `local s = "xxxxxxxxxxxxxxxx" while true do s = string.rep(s, 2) end`, false},
	} {
		name, src := c.name, c.src
		t.Run(name, func(t *testing.T) {
			r := New(Manifest{ID: "bomb"}, "")
			defer r.Close()
			var err error
			peak := peakHeap(t, func() {
				err = r.Load("beacle.on('go', function() "+src+" end)", "bomb.lua")
				if err == nil {
					_, err = r.Handle("go", nil, CallTimeout)
				}
			})
			if err == nil || !strings.Contains(err.Error(), "MB") {
				t.Fatalf("want a memory error, got %v", err)
			}
			if c.stops && r.Err() == "" {
				t.Error("the plugin was not stopped")
			}
			t.Logf("peak heap %d MB", peak>>20)
			if peak > 1<<30 {
				t.Errorf("heap reached %d MB before it was stopped", peak>>20)
			}
		})
	}
}

// Building a long string piece by piece makes plenty of garbage; that is not
// a plugin keeping memory, and must not be mistaken for one.
func TestGarbageIsNotHeldAgainstAPlugin(t *testing.T) {
	r := newTest(t, Manifest{}, `
beacle.on("build", function()
  local s = ""
  for i = 1, 5000 do s = s .. "a line of output, more or less this long\n" end
  return #s
end)`)
	for range 3 {
		v, err := r.Handle("build", nil, 5*time.Second)
		if err != nil || v != float64(5000*41) {
			t.Fatalf("got %v, %v", v, err)
		}
	}
	if r.Err() != "" {
		t.Fatal(r.Err())
	}
}

// What a plugin keeps between calls is bounded too: here a cache that grows
// by a megabyte a call.
func TestPluginKeepingTooMuchIsStopped(t *testing.T) {
	was, wasEvery := RetainedMemoryLimit, sizeEvery
	RetainedMemoryLimit, sizeEvery = 8<<20, 0
	t.Cleanup(func() { RetainedMemoryLimit, sizeEvery = was, wasEvery })
	r := newTest(t, Manifest{}, `
local cache = {}
beacle.on("grow", function()
  cache[#cache + 1] = string.rep(tostring(#cache), 1048576)
end)`)
	for i := 0; i < 20 && r.Err() == ""; i++ {
		_, _ = r.Handle("grow", nil, time.Second)
	}
	if !strings.Contains(r.Err(), "keeps more than 8 MB") {
		t.Fatalf("want the plugin stopped for what it keeps, got %q", r.Err())
	}
}

// A table that holds the same table twice, thirty levels deep, is a billion
// values once written out as JSON.
func TestSharedTablesDoNotExplode(t *testing.T) {
	r := newTest(t, Manifest{}, `
beacle.on("dag", function()
  local t = {1}
  for i = 1, 30 do t = {t, t} end
  return #beacle.json.encode(t)
end)`)
	peak := peakHeap(t, func() { call(t, r, "dag", nil) })
	if peak > 512<<20 {
		t.Errorf("heap reached %d MB", peak>>20)
	}
}

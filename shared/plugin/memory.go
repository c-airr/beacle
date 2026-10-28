package plugin

import (
	"fmt"
	"runtime"
	"runtime/metrics"
	"sync"
	"time"

	lua "github.com/yuin/gopher-lua"
)

// A plugin shares the process with the agent or the panel, so a runaway
// one (s = s .. s in a loop, a table grown without end) must be stopped
// before it takes the whole process down with it. gopher-lua has no
// allocation hook, so memory is watched from three sides:
//
//   - while a call runs, a sampler compares the heap against where it stood
//     when the call began, and cancels a call that grew it past
//     CallMemoryLimit — the VM stops at its next instruction;
//   - the library functions that can allocate a huge result in one go
//     (string.rep, string.gsub, table.concat, conversions to JSON) refuse
//     before allocating, since nothing interrupts a single Go call;
//   - what a plugin keeps between calls is measured now and then by walking
//     its state, and a plugin over RetainedMemoryLimit is stopped.
//
// A plugin stopped this way says so on its card.

var (
	// CallMemoryLimit is how far one call may grow the heap.
	CallMemoryLimit uint64 = 32 << 20
	// RetainedMemoryLimit is what a plugin may keep in its Lua state.
	RetainedMemoryLimit uint64 = 32 << 20
	// sizeEvery is how often a running plugin's state is measured.
	sizeEvery = 30 * time.Second
	// memSampleEvery is the sampler's period while a call runs.
	memSampleEvery = 2 * time.Millisecond
)

// errMemory is what a call cancelled for memory returns.
type errMemory struct{ limit uint64 }

func (e errMemory) Error() string {
	return fmt.Sprintf("used more than %d MB of memory", e.limit>>20)
}

type activeCall struct {
	startLive uint64 // live heap at the last GC before the call began
	nextCheck uint64 // heap size that triggers a closer look
	cancel    func()
	over      bool
	alone     bool // the only call running when it was cancelled
}

type memWatch struct {
	mu     sync.Mutex
	active map[*activeCall]struct{}
	wake   chan struct{}
}

var watch = &memWatch{active: map[*activeCall]struct{}{}, wake: make(chan struct{}, 1)}

func init() { go watch.run() }

var heapSamples = []metrics.Sample{{Name: "/memory/classes/heap/objects:bytes"}, {Name: "/gc/heap/live:bytes"}}

// heap returns the heap in use, garbage included, and the live heap as of
// the last GC.
func heap() (inUse, live uint64) {
	s := make([]metrics.Sample, len(heapSamples))
	copy(s, heapSamples)
	metrics.Read(s)
	return s[0].Value.Uint64(), s[1].Value.Uint64()
}

func (w *memWatch) enter(cancel func()) *activeCall {
	inUse, live := heap()
	c := &activeCall{startLive: live, nextCheck: inUse + CallMemoryLimit, cancel: cancel}
	w.mu.Lock()
	w.active[c] = struct{}{}
	w.mu.Unlock()
	select {
	case w.wake <- struct{}{}:
	default:
	}
	return c
}

// leave reports whether the call was cancelled for memory, and whether it
// was the only call running then, so the blame is certain.
func (w *memWatch) leave(c *activeCall) (over, alone bool) {
	w.mu.Lock()
	defer w.mu.Unlock()
	delete(w.active, c)
	return c.over, c.alone
}

func (w *memWatch) run() {
	for {
		w.mu.Lock()
		idle := len(w.active) == 0
		w.mu.Unlock()
		if idle {
			<-w.wake
			continue
		}
		time.Sleep(memSampleEvery)
		w.check()
	}
}

func (w *memWatch) check() {
	inUse, _ := heap()
	w.mu.Lock()
	suspect := false
	for c := range w.active {
		if !c.over && inUse > c.nextCheck {
			suspect = true
		}
	}
	w.mu.Unlock()
	if !suspect {
		return
	}
	// The heap counts garbage nobody has collected yet: a call that built
	// a long string piece by piece looks just like one that keeps it.
	// Collect, then judge by what is still alive.
	runtime.GC()
	inUse, live := heap()
	w.mu.Lock()
	defer w.mu.Unlock()
	for c := range w.active {
		if c.over {
			continue
		}
		if live > c.startLive && live-c.startLive > CallMemoryLimit {
			c.over, c.alone = true, len(w.active) == 1
			c.cancel()
		} else {
			c.nextCheck = inUse + CallMemoryLimit
		}
	}
}

// guardLibs replaces the library functions that can build a huge value in
// one Go call with ones that refuse first.
func guardLibs(L *lua.LState) {
	wrap := func(lib, name string, check func(L *lua.LState) uint64) {
		t, _ := L.GetGlobal(lib).(*lua.LTable)
		if t == nil {
			return
		}
		orig, _ := t.RawGetString(name).(*lua.LFunction)
		if orig == nil || orig.GFunction == nil {
			return
		}
		fn := orig.GFunction
		t.RawSetString(name, L.NewFunction(func(L *lua.LState) int {
			if n := check(L); n > CallMemoryLimit {
				L.RaiseError("%s.%s: the result would be %d MB, more than a plugin may use", lib, name, n>>20)
			}
			return fn(L)
		}))
	}
	strLen := func(L *lua.LState, i int) uint64 {
		if s, ok := L.Get(i).(lua.LString); ok {
			return uint64(len(s))
		}
		if n, ok := L.Get(i).(lua.LNumber); ok {
			return uint64(len(n.String()))
		}
		return 0
	}
	count := func(L *lua.LState, i int) uint64 {
		n, ok := L.Get(i).(lua.LNumber)
		if !ok || n <= 0 {
			return 0
		}
		if float64(n) > 1<<53 {
			return 1 << 53
		}
		return uint64(n)
	}
	mul := func(a, b uint64) uint64 {
		if a != 0 && b > (1<<62)/a {
			return 1 << 62
		}
		return a * b
	}
	wrap("string", "rep", func(L *lua.LState) uint64 {
		return mul(strLen(L, 1), count(L, 2))
	})
	// Every match can become the replacement; a string or a table of them
	// is known up front, a function's results are checked as they come.
	wrap("string", "gsub", func(L *lua.LState) uint64 {
		src := strLen(L, 1)
		matches := src + 1
		if n := count(L, 4); n > 0 && n < matches {
			matches = n
		}
		var repl uint64
		switch r := L.Get(3).(type) {
		case lua.LString:
			repl = uint64(len(r))
		case *lua.LTable:
			r.ForEach(func(_, v lua.LValue) {
				if s, ok := v.(lua.LString); ok && uint64(len(s)) > repl {
					repl = uint64(len(s))
				}
			})
		}
		return src + mul(matches, repl)
	})
	wrap("table", "concat", func(L *lua.LState) uint64 {
		t, ok := L.Get(1).(*lua.LTable)
		if !ok {
			return 0
		}
		n := uint64(t.MaxN())
		var total uint64
		for i := 1; i <= int(n) && total <= CallMemoryLimit; i++ {
			if s, ok := t.RawGetInt(i).(lua.LString); ok {
				total += uint64(len(s))
			}
		}
		return total + mul(n, strLen(L, 2))
	})
}

// stateSize estimates the bytes a plugin's Lua state holds, reachable from
// its globals, the registry and the functions the host keeps. It stops
// counting past limit.
func stateSize(roots []lua.LValue, limit uint64) uint64 {
	seen := map[any]struct{}{}
	var size uint64
	stack := append([]lua.LValue(nil), roots...)
	for len(stack) > 0 && size <= limit {
		v := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		switch v := v.(type) {
		case lua.LString:
			size += 16 + uint64(len(v))
		case *lua.LTable:
			if _, ok := seen[v]; ok {
				continue
			}
			seen[v] = struct{}{}
			size += 64
			if v.Metatable != nil {
				stack = append(stack, v.Metatable)
			}
			v.ForEach(func(k, val lua.LValue) {
				size += 40
				stack = append(stack, k, val)
			})
		case *lua.LFunction:
			if _, ok := seen[v]; ok {
				continue
			}
			seen[v] = struct{}{}
			size += 64
			if v.Env != nil {
				stack = append(stack, v.Env)
			}
			for _, uv := range v.Upvalues {
				if uv != nil {
					size += 16
					stack = append(stack, uv.Value())
				}
			}
		}
	}
	return size
}

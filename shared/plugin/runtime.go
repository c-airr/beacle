package plugin

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"strings"
	"sync"
	"time"

	lua "github.com/yuin/gopher-lua"
)

const (
	// CallTimeout bounds one call into a plugin: a task, a handler or the
	// top-level chunk. Host functions (exec, http) inherit it, so a hung
	// program cannot hold the plugin past it either.
	CallTimeout = 10 * time.Second
	// MinEvery is the shortest beacle.every interval.
	MinEvery = 5 * time.Second
	// Consecutive task failures before the plugin is stopped.
	maxFailures = 5
	logLines    = 200
	storeMax    = 64 << 10
)

// Runtime is one plugin's Lua state. gopher-lua is single-threaded, so every
// entry into Lua goes through mu.
type Runtime struct {
	Manifest Manifest

	mu       sync.Mutex
	L        *lua.LState
	lib      *lua.LTable
	handlers map[string]*lua.LFunction
	tasks    []task
	stop     chan struct{}
	closed   bool
	// kept are Lua values the host holds outside the state (slot
	// functions), counted with it by stateSize.
	kept      []lua.LValue
	memStrike int
	sizedAt   time.Time

	// Read from other goroutines while a call may hold mu for seconds.
	dataMu   sync.Mutex
	logs     []string
	values   map[string]float64
	errMsg   string
	storeVal map[string]any

	storePath string

	// Config is the user's settings, defaults filled in (see ConfigValues).
	// Set before Load.
	Config map[string]any
}

type task struct {
	every time.Duration
	fn    *lua.LFunction
}

// New builds the sandbox: base (without anything that loads code), string,
// table and math. No os, io, debug, package or coroutine. storePath keeps
// beacle.store across restarts; empty keeps it in memory.
func New(m Manifest, storePath string) *Runtime {
	L := lua.NewState(lua.Options{SkipOpenLibs: true, CallStackSize: 200, RegistryMaxSize: 1 << 20})
	for _, lib := range []struct {
		name string
		fn   lua.LGFunction
	}{{lua.BaseLibName, lua.OpenBase}, {lua.TabLibName, lua.OpenTable}, {lua.StringLibName, lua.OpenString}, {lua.MathLibName, lua.OpenMath}} {
		L.Push(L.NewFunction(lib.fn))
		L.Push(lua.LString(lib.name))
		L.Call(1, 0)
	}
	for _, name := range []string{"dofile", "loadfile", "load", "loadstring", "require", "module", "_printregs", "collectgarbage"} {
		L.SetGlobal(name, lua.LNil)
	}
	guardLibs(L)
	r := &Runtime{
		Manifest:  m,
		L:         L,
		lib:       L.NewTable(),
		handlers:  map[string]*lua.LFunction{},
		stop:      make(chan struct{}),
		values:    map[string]float64{},
		storeVal:  map[string]any{},
		storePath: storePath,
	}
	if storePath != "" {
		if b, err := os.ReadFile(storePath); err == nil {
			_ = json.Unmarshal(b, &r.storeVal)
		}
	}
	L.SetGlobal("beacle", r.lib)
	L.SetGlobal("print", L.NewFunction(r.luaLog))
	r.Set("log", r.luaLog)
	r.Set("now", luaNow)
	r.Set("date", luaDate)
	r.Set("config", r.luaConfig)
	r.Set("every", r.luaEvery)
	r.Set("on", r.luaOn)
	r.SetIn("json", "encode", luaJSONEncode)
	r.SetIn("json", "decode", luaJSONDecode)
	r.SetIn("base64", "encode", luaBase64Encode)
	r.SetIn("base64", "decode", luaBase64Decode)
	r.SetIn("store", "get", r.luaStoreGet)
	r.SetIn("store", "set", r.luaStoreSet)
	return r
}

// Set adds beacle.<name>.
func (r *Runtime) Set(name string, fn lua.LGFunction) {
	r.lib.RawSetString(name, r.L.NewFunction(fn))
}

// SetIn adds beacle.<table>.<name>.
func (r *Runtime) SetIn(table, name string, fn lua.LGFunction) {
	t, ok := r.lib.RawGetString(table).(*lua.LTable)
	if !ok {
		t = r.L.NewTable()
		r.lib.RawSetString(table, t)
	}
	t.RawSetString(name, r.L.NewFunction(fn))
}

// Keep tells the runtime the host holds v (a slot function), so what it
// keeps alive counts towards the plugin's memory.
func (r *Runtime) Keep(v lua.LValue) {
	r.kept = append(r.kept, v)
}

// Load runs the plugin's top-level chunk (which registers tasks, handlers,
// slots) and starts its tasks.
func (r *Runtime) Load(src, chunk string) error {
	fn, err := r.L.Load(strings.NewReader(src), chunk)
	if err != nil {
		r.fail(err)
		return err
	}
	if _, err := r.Call(fn, r.Manifest.CallTimeout()); err != nil {
		r.fail(err)
		return err
	}
	r.mu.Lock()
	tasks := r.tasks
	r.mu.Unlock()
	for _, t := range tasks {
		go r.runTask(t)
	}
	return nil
}

// Call runs fn with a deadline. Arguments and the (first) result are plain Go
// values in the JSON shapes, converted while the state is held — building a
// Lua table outside the lock would race a running task. A Lua error,
// including an interrupted endless loop, comes back as err with the plugin
// still usable.
//
// A call that runs away with memory is cancelled (see memory.go). Twice in
// a row, or once while it was the only plugin running so the blame is
// certain, stops the plugin.
func (r *Runtime) Call(fn *lua.LFunction, timeout time.Duration, args ...any) (any, error) {
	ret, err, stop := r.call(fn, timeout, args)
	if stop != nil {
		r.fail(stop)
	}
	return ret, err
}

func (r *Runtime) call(fn *lua.LFunction, timeout time.Duration, args []any) (ret any, err, stop error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return nil, errors.New("plugin stopped"), nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	r.L.SetContext(ctx)
	defer r.L.RemoveContext()
	largs := make([]lua.LValue, len(args))
	for i, a := range args {
		largs[i] = FromGo(r.L, a)
	}
	mc := watch.enter(cancel)
	callErr := r.L.CallByParam(lua.P{Fn: fn, NRet: 1, Protect: true}, largs...)
	if over, alone := watch.leave(mc); over {
		// Drop what the runaway call built before anything else allocates.
		r.L.SetTop(0)
		r.memStrike++
		if alone {
			r.memStrike++
		}
		err = errMemory{CallMemoryLimit}
		if r.memStrike >= 2 {
			return nil, err, err
		}
		return nil, err, nil
	}
	if callErr != nil {
		if ctx.Err() != nil {
			return nil, fmt.Errorf("timed out after %s", timeout), nil
		}
		return nil, luaErr(callErr), nil
	}
	r.memStrike = 0
	ret = ToGo(r.L.Get(-1))
	r.L.Pop(1)
	if time.Since(r.sizedAt) >= sizeEvery {
		r.sizedAt = time.Now()
		roots := append([]lua.LValue{r.L.G.Global, r.L.G.Registry}, r.kept...)
		for _, h := range r.handlers {
			roots = append(roots, h)
		}
		for _, t := range r.tasks {
			roots = append(roots, t.fn)
		}
		if n := stateSize(roots, RetainedMemoryLimit); n > RetainedMemoryLimit {
			return ret, nil, fmt.Errorf("keeps more than %d MB in memory", RetainedMemoryLimit>>20)
		}
	}
	return ret, nil, nil
}

// Handle calls a handler registered with beacle.on.
func (r *Runtime) Handle(name string, args any, timeout time.Duration) (any, error) {
	r.mu.Lock()
	fn := r.handlers[name]
	r.mu.Unlock()
	if fn == nil {
		return nil, fmt.Errorf("no handler %q", name)
	}
	return r.Call(fn, timeout, args)
}

// HasHandler reports whether beacle.on registered name.
func (r *Runtime) HasHandler(name string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.handlers[name] != nil
}

func (r *Runtime) runTask(t task) {
	failures := 0
	tick := time.NewTicker(t.every)
	defer tick.Stop()
	for {
		if _, err := r.Call(t.fn, r.Manifest.CallTimeout()); err != nil {
			failures++
			r.Logf("error: %v", err)
			if failures >= maxFailures {
				r.fail(fmt.Errorf("stopped after %d failures in a row: %v", failures, err))
				return
			}
		} else {
			failures = 0
		}
		select {
		case <-r.stop:
			return
		case <-tick.C:
		}
	}
}

// fail puts the plugin in the error state: tasks stop and its metrics go,
// since a value nobody refreshes any more would look current.
func (r *Runtime) fail(err error) {
	r.dataMu.Lock()
	r.errMsg = luaErr(err).Error()
	r.values = map[string]float64{}
	r.dataMu.Unlock()
	r.Logf("error: %s", r.errMsg)
	r.mu.Lock()
	if !r.closed {
		r.closed = true
		close(r.stop)
		go r.L.Close() // not under mu: Close must not wait for a stuck call
	}
	r.mu.Unlock()
}

// Err is the reason the plugin stopped, or "".
func (r *Runtime) Err() string {
	r.dataMu.Lock()
	defer r.dataMu.Unlock()
	return r.errMsg
}

// Close stops tasks and frees the Lua state.
func (r *Runtime) Close() {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return
	}
	r.closed = true
	close(r.stop)
	r.L.Close()
}

// Logs returns the last lines logged by the plugin.
func (r *Runtime) Logs() []string {
	r.dataMu.Lock()
	defer r.dataMu.Unlock()
	return append([]string(nil), r.logs...)
}

func (r *Runtime) Logf(format string, args ...any) {
	line := time.Now().Format("15:04:05 ") + fmt.Sprintf(format, args...)
	log.Printf("plugin %s: %s", r.Manifest.ID, line[9:])
	r.dataMu.Lock()
	r.logs = append(r.logs, line)
	if len(r.logs) > logLines {
		r.logs = r.logs[len(r.logs)-logLines:]
	}
	r.dataMu.Unlock()
}

func luaErr(err error) error {
	var ae *lua.ApiError
	if errors.As(err, &ae) && ae.Object != nil {
		return errors.New(ae.Object.String())
	}
	return err
}

func (r *Runtime) luaLog(L *lua.LState) int {
	parts := make([]string, L.GetTop())
	for i := range parts {
		parts[i] = L.ToStringMeta(L.Get(i + 1)).String()
	}
	r.Logf("%s", strings.Join(parts, " "))
	return 0
}

func (r *Runtime) luaEvery(L *lua.LState) int {
	sec := float64(L.CheckNumber(1))
	fn := L.CheckFunction(2)
	every := time.Duration(sec * float64(time.Second))
	if every < MinEvery {
		L.ArgError(1, fmt.Sprintf("at least %d seconds", int(MinEvery.Seconds())))
	}
	r.tasks = append(r.tasks, task{every: every, fn: fn}) // called under mu
	return 0
}

func (r *Runtime) luaOn(L *lua.LState) int {
	r.handlers[L.CheckString(1)] = L.CheckFunction(2) // called under mu
	return 0
}

func (r *Runtime) luaStoreGet(L *lua.LState) int {
	r.dataMu.Lock()
	v := r.storeVal[L.CheckString(1)]
	r.dataMu.Unlock()
	L.Push(FromGo(L, v))
	return 1
}

func (r *Runtime) luaStoreSet(L *lua.LState) int {
	key := L.CheckString(1)
	r.dataMu.Lock()
	old, had := r.storeVal[key]
	if v := ToGo(L.Get(2)); v == nil {
		delete(r.storeVal, key)
	} else {
		r.storeVal[key] = v
	}
	b, _ := json.Marshal(r.storeVal)
	if len(b) > storeMax {
		if had {
			r.storeVal[key] = old
		} else {
			delete(r.storeVal, key)
		}
		r.dataMu.Unlock()
		L.RaiseError("beacle.store is full (64 KiB)")
		return 0
	}
	r.dataMu.Unlock()
	if r.storePath != "" {
		tmp := r.storePath + ".tmp"
		if err := os.WriteFile(tmp, b, 0o600); err == nil {
			err = os.Rename(tmp, r.storePath)
			if err != nil {
				r.Logf("store: %v", err)
			}
		} else {
			r.Logf("store: %v", err)
		}
	}
	return 0
}

func luaJSONEncode(L *lua.LState) int {
	b, err := json.Marshal(ToGo(L.Get(1)))
	if err != nil {
		L.Push(lua.LNil)
		L.Push(lua.LString(err.Error()))
		return 2
	}
	L.Push(lua.LString(b))
	return 1
}

func luaJSONDecode(L *lua.LState) int {
	var v any
	if err := json.Unmarshal([]byte(L.CheckString(1)), &v); err != nil {
		L.Push(lua.LNil)
		L.Push(lua.LString(err.Error()))
		return 2
	}
	L.Push(FromGo(L, v))
	return 1
}

// luaBase64Encode: beacle.base64.encode(text), standard alphabet with
// padding — what an Authorization: Basic header wants.
func luaBase64Encode(L *lua.LState) int {
	L.Push(lua.LString(base64.StdEncoding.EncodeToString([]byte(L.CheckString(1)))))
	return 1
}

// luaBase64Decode: beacle.base64.decode(text) → text | nil, err. Padding is
// optional.
func luaBase64Decode(L *lua.LState) int {
	in := strings.TrimRight(strings.TrimSpace(L.CheckString(1)), "=")
	b, err := base64.RawStdEncoding.DecodeString(in)
	if err != nil {
		L.Push(lua.LNil)
		L.Push(lua.LString(err.Error()))
		return 2
	}
	L.Push(lua.LString(b))
	return 1
}

// luaNow: beacle.now() is the time in seconds since 1970, with milliseconds.
func luaNow(L *lua.LState) int {
	L.Push(lua.LNumber(float64(time.Now().UnixMilli()) / 1000))
	return 1
}

// luaDate: beacle.date([t], [layout]) formats t (default now) in this
// computer's time zone. layout is Go's ("2006-01-02 15:04"); the default is
// "2006-01-02 15:04:05".
func luaDate(L *lua.LState) int {
	t := time.Now()
	if L.Get(1) != lua.LNil {
		sec := float64(L.CheckNumber(1))
		t = time.UnixMilli(int64(sec * 1000))
	}
	L.Push(lua.LString(t.Format(L.OptString(2, "2006-01-02 15:04:05"))))
	return 1
}

// luaConfig: beacle.config(key) is one setting, beacle.config() all of them.
func (r *Runtime) luaConfig(L *lua.LState) int {
	if L.GetTop() == 0 {
		L.Push(FromGo(L, r.Config))
		return 1
	}
	L.Push(FromGo(L, r.Config[L.CheckString(1)]))
	return 1
}

// ConfigValues is what a plugin sees through beacle.config: each field's
// stored value, else its default. Fields the manifest no longer has are
// dropped; agent leaves secrets out.
func ConfigValues(m Manifest, stored map[string]any, agent bool) map[string]any {
	out := map[string]any{}
	for _, f := range m.Config {
		if agent && f.Type == "secret" {
			continue
		}
		if v, ok := stored[f.Key]; ok && v != nil {
			out[f.Key] = v
		} else if f.Default != nil {
			out[f.Key] = f.Default
		}
	}
	return out
}

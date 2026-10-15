package plugin

import (
	"context"
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

	// Read from other goroutines while a call may hold mu for seconds.
	dataMu   sync.Mutex
	logs     []string
	values   map[string]float64
	errMsg   string
	storeVal map[string]any

	storePath string
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
	r.Set("every", r.luaEvery)
	r.Set("on", r.luaOn)
	r.SetIn("json", "encode", luaJSONEncode)
	r.SetIn("json", "decode", luaJSONDecode)
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

// Load runs the plugin's top-level chunk (which registers tasks, handlers,
// slots) and starts its tasks.
func (r *Runtime) Load(src, chunk string) error {
	fn, err := r.L.Load(strings.NewReader(src), chunk)
	if err != nil {
		r.fail(err)
		return err
	}
	if _, err := r.Call(fn, CallTimeout); err != nil {
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

// Call runs fn with a deadline and returns its first result. A Lua error,
// including an interrupted endless loop, comes back as err with the plugin
// still usable.
func (r *Runtime) Call(fn *lua.LFunction, timeout time.Duration, args ...lua.LValue) (lua.LValue, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return lua.LNil, errors.New("plugin stopped")
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	r.L.SetContext(ctx)
	defer r.L.RemoveContext()
	if err := r.L.CallByParam(lua.P{Fn: fn, NRet: 1, Protect: true}, args...); err != nil {
		if ctx.Err() != nil {
			return lua.LNil, fmt.Errorf("timed out after %s", timeout)
		}
		return lua.LNil, luaErr(err)
	}
	ret := r.L.Get(-1)
	r.L.Pop(1)
	return ret, nil
}

// Handle calls a handler registered with beacle.on, converting to and from
// plain Go values (the JSON shapes).
func (r *Runtime) Handle(name string, args any, timeout time.Duration) (any, error) {
	r.mu.Lock()
	fn := r.handlers[name]
	r.mu.Unlock()
	if fn == nil {
		return nil, fmt.Errorf("no handler %q", name)
	}
	ret, err := r.Call(fn, timeout, FromGo(r.L, args))
	if err != nil {
		return nil, err
	}
	return ToGo(ret), nil
}

func (r *Runtime) runTask(t task) {
	failures := 0
	tick := time.NewTicker(t.every)
	defer tick.Stop()
	for {
		if _, err := r.Call(t.fn, CallTimeout); err != nil {
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

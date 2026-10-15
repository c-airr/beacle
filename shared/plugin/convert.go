package plugin

import lua "github.com/yuin/gopher-lua"

// maxDepth stops a table that contains itself from recursing forever.
const maxDepth = 32

// ToGo turns a Lua value into the shapes encoding/json uses: nil, bool,
// float64, string, []any, map[string]any. A table with keys 1..n is a list;
// an empty table is an empty list. Functions and userdata become nil.
func ToGo(v lua.LValue) any { return toGo(v, 0) }

func toGo(v lua.LValue, depth int) any {
	switch v := v.(type) {
	case lua.LBool:
		return bool(v)
	case lua.LNumber:
		return float64(v)
	case lua.LString:
		return string(v)
	case *lua.LTable:
		if depth >= maxDepth {
			return nil
		}
		n, keys := v.MaxN(), 0
		v.ForEach(func(lua.LValue, lua.LValue) { keys++ })
		if keys == n {
			list := make([]any, 0, n)
			for i := 1; i <= n; i++ {
				list = append(list, toGo(v.RawGetInt(i), depth+1))
			}
			return list
		}
		m := make(map[string]any, keys)
		v.ForEach(func(k, val lua.LValue) {
			m[k.String()] = toGo(val, depth+1)
		})
		return m
	}
	return nil
}

// FromGo is the reverse of ToGo.
func FromGo(L *lua.LState, v any) lua.LValue {
	switch v := v.(type) {
	case nil:
		return lua.LNil
	case bool:
		return lua.LBool(v)
	case float64:
		return lua.LNumber(v)
	case int:
		return lua.LNumber(v)
	case string:
		return lua.LString(v)
	case []string:
		t := L.CreateTable(len(v), 0)
		for _, s := range v {
			t.Append(lua.LString(s))
		}
		return t
	case []any:
		t := L.CreateTable(len(v), 0)
		for _, e := range v {
			t.Append(FromGo(L, e))
		}
		return t
	case map[string]any:
		t := L.CreateTable(0, len(v))
		for k, e := range v {
			t.RawSetString(k, FromGo(L, e))
		}
		return t
	}
	return lua.LNil
}

package plugin

import lua "github.com/yuin/gopher-lua"

// maxDepth stops a table that contains itself from recursing forever.
const maxDepth = 32

// maxNodes bounds one conversion. A table can hold the same table twice,
// and that one twice again: thirty levels of it are a few lines of Lua and
// a billion values once copied out. Past the budget (a quarter million
// values, or 16 MB of strings) the rest becomes nil.
const maxNodes = 1 << 18

// ToGo turns a Lua value into the shapes encoding/json uses: nil, bool,
// float64, string, []any, map[string]any. A table with keys 1..n is a list;
// an empty table is an empty list. Functions and userdata become nil.
func ToGo(v lua.LValue) any {
	budget := maxNodes
	return toGo(v, 0, &budget)
}

func toGo(v lua.LValue, depth int, budget *int) any {
	if *budget <= 0 {
		return nil
	}
	*budget--
	switch v := v.(type) {
	case lua.LBool:
		return bool(v)
	case lua.LNumber:
		return float64(v)
	case lua.LString:
		// Shared, not copied — but it is written out once per place.
		*budget -= len(v) / 64
		return string(v)
	case *lua.LTable:
		if depth >= maxDepth {
			return nil
		}
		n, keys := v.MaxN(), 0
		v.ForEach(func(lua.LValue, lua.LValue) { keys++ })
		if keys == n {
			list := make([]any, 0, min(n, max(*budget, 0)))
			for i := 1; i <= n && *budget > 0; i++ {
				list = append(list, toGo(v.RawGetInt(i), depth+1, budget))
			}
			return list
		}
		m := make(map[string]any, min(keys, max(*budget, 0)))
		v.ForEach(func(k, val lua.LValue) {
			m[k.String()] = toGo(val, depth+1, budget)
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

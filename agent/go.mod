module beacle/agent

go 1.26

require (
	beacle/shared v0.0.0
	github.com/coreos/go-systemd/v22 v22.7.0
	github.com/creack/pty v1.1.24
	github.com/gorilla/websocket v1.5.3
)

require (
	github.com/godbus/dbus/v5 v5.1.0 // indirect
	github.com/google/btree v1.1.2 // indirect
	github.com/yuin/gopher-lua v1.1.2 // indirect
	golang.org/x/crypto v0.37.0 // indirect
	golang.org/x/net v0.39.0 // indirect
	golang.org/x/sys v0.32.0 // indirect
	golang.org/x/time v0.7.0 // indirect
	golang.zx2c4.com/wintun v0.0.0-20230126152724-0fa3db229ce2 // indirect
	golang.zx2c4.com/wireguard v0.0.0-20260522210424-ecfc5a8d5446 // indirect
	gvisor.dev/gvisor v0.0.0-20250503011706-39ed1f5ac29c // indirect
)

replace beacle/shared => ../shared

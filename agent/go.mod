module beacle/agent

go 1.26

require (
	beacle/shared v0.0.0
	github.com/coreos/go-systemd/v22 v22.7.0
	github.com/gorilla/websocket v1.5.3
)

require github.com/godbus/dbus/v5 v5.1.0 // indirect

replace beacle/shared => ../shared

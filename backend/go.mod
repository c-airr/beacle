module beacle/backend

go 1.26

require (
	beacle/shared v0.0.0
	github.com/gorilla/websocket v1.5.3
)

require (
	golang.org/x/crypto v0.37.0 // indirect
	golang.org/x/net v0.39.0 // indirect
	golang.org/x/sys v0.32.0 // indirect
	golang.zx2c4.com/wintun v0.0.0-20230126152724-0fa3db229ce2 // indirect
	golang.zx2c4.com/wireguard v0.0.0-20260522210424-ecfc5a8d5446 // indirect
)

replace beacle/shared => ../shared

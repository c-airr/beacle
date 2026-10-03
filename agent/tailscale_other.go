//go:build !linux

package main

import (
	"context"
	"errors"
)

func tailscaleIPv4() string { return "" }
func tailscaleName() string { return "" }

func removeTailscale(context.Context) (string, error) {
	return "", errors.New("removing Tailscale is only supported on Linux")
}

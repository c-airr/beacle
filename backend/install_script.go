package main

import (
	_ "embed"
	"fmt"
	"strings"
)

//go:embed install-agent.sh
var installAgentScript string

func vpsInstallCommand(backendURL string) string {
	url := strings.TrimRight(backendURL, "/")
	return fmt.Sprintf("curl -fsSL %s/install | sudo bash", url)
}

func installScript(backendURL string) string {
	url := strings.TrimRight(backendURL, "/")
	return fmt.Sprintf("# Beacle auto-install — backend %s\nBEACLE_BACKEND_URL=%q\n%s", url, url, installAgentScript)
}

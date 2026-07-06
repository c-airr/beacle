package main

import (
	"flag"
	"fmt"
	"os"
)

func main() {
	if len(os.Args) >= 2 && os.Args[1] == "set" {
		runPairSet(os.Args[1:])
		return
	}

	var (
		configPath = flag.String("config", "/opt/beacle-agent/config.json", "path to config file")
		version    = flag.Bool("version", false, "print version and exit")
	)
	flag.Parse()

	if *version {
		fmt.Println(AgentVersion)
		return
	}

	runAgent(*configPath)
}

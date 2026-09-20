// svc is a tiny operations CLI used to demo AI coding sessions in Docker Sandboxes.
package main

import (
	"fmt"
	"os"

	"github.com/chainloop-dev/sbx-demo/go/internal/status"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	switch os.Args[1] {
	case "status":
		report := status.Collect()
		fmt.Print(status.Render(report))
		if !report.Healthy() {
			os.Exit(1)
		}
	default:
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: svc status")
}

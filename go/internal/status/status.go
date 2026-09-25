// Package status collects and renders the health of the service's components.
package status

import (
	"fmt"
	"strings"
	"time"
)

// Component is one checked subsystem.
type Component struct {
	Name    string
	OK      bool
	Latency time.Duration
	Detail  string
}

// Report is the result of one status collection.
type Report struct {
	CheckedAt  time.Time
	Components []Component
}

// Healthy is true when every component is OK.
func (r Report) Healthy() bool {
	for _, c := range r.Components {
		if !c.OK {
			return false
		}
	}
	return true
}

// Collect runs the checks. The checks are simulated so the demo has no external dependencies.
func Collect() Report {
	return Report{
		CheckedAt: time.Now().UTC(),
		Components: []Component{
			{Name: "api", OK: true, Latency: 12 * time.Millisecond, Detail: "200 OK"},
			{Name: "database", OK: true, Latency: 3 * time.Millisecond, Detail: "connections 4/50"},
			{Name: "queue", OK: true, Latency: 8 * time.Millisecond, Detail: "depth 0"},
			{Name: "eventbus", OK: true, Latency: 5 * time.Millisecond, Detail: "subscribers 3, lag 0"},
		},
	}
}

// Render formats a report as a plain-text table.
func Render(r Report) string {
	var b strings.Builder
	fmt.Fprintf(&b, "checked at %s\n", r.CheckedAt.Format(time.RFC3339))
	fmt.Fprintf(&b, "%-10s %-6s %-8s %s\n", "COMPONENT", "STATUS", "LATENCY", "DETAIL")
	for _, c := range r.Components {
		state := "ok"
		if !c.OK {
			state = "FAIL"
		}
		fmt.Fprintf(&b, "%-10s %-6s %-8s %s\n", c.Name, state, c.Latency, c.Detail)
	}
	return b.String()
}

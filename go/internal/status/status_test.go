package status

import (
	"strings"
	"testing"
	"time"
)

func TestHealthy(t *testing.T) {
	r := Report{Components: []Component{{Name: "a", OK: true}, {Name: "b", OK: true}}}
	if !r.Healthy() {
		t.Fatal("expected healthy report")
	}
	r.Components[1].OK = false
	if r.Healthy() {
		t.Fatal("expected unhealthy report")
	}
}

func TestRender(t *testing.T) {
	r := Report{
		CheckedAt:  time.Date(2026, 9, 25, 10, 0, 0, 0, time.UTC),
		Components: []Component{{Name: "api", OK: true, Latency: 12 * time.Millisecond, Detail: "200 OK"}},
	}
	out := Render(r)
	for _, want := range []string{"checked at 2026-09-25T10:00:00Z", "COMPONENT", "api", "ok", "12ms", "200 OK"} {
		if !strings.Contains(out, want) {
			t.Errorf("output missing %q:\n%s", want, out)
		}
	}
}

func TestCollectIncludesEventBus(t *testing.T) {
	for _, c := range Collect().Components {
		if c.Name == "eventbus" {
			return
		}
	}
	t.Fatal("expected an eventbus component in the report")
}

package service

import (
	"bufio"
	"errors"
	"io"
	"testing"
	"time"
)

func TestAnthropicNativeLinePumpKeepaliveDoesNotResetUpstreamIdle(t *testing.T) {
	reader, writer := io.Pipe()
	defer reader.Close()
	defer writer.Close()
	pump := newAnthropicNativeLinePump(bufio.NewScanner(reader), 30*time.Millisecond)
	ticker := time.NewTicker(time.Millisecond)
	defer ticker.Stop()
	pump.tick = ticker.C
	ticks := 0
	pump.onTick = func() { ticks++ }
	type outcome struct {
		err   error
		ticks int
	}
	finished := make(chan outcome, 1)
	go func() {
		defer pump.stop()
		_, err := pump.next()
		finished <- outcome{err: err, ticks: ticks}
	}()
	select {
	case result := <-finished:
		if !errors.Is(result.err, errAnthropicNativeStreamIdle) {
			t.Fatalf("want upstream idle timeout, got %v", result.err)
		}
		if result.ticks == 0 {
			t.Fatal("expected downstream keepalive while waiting for upstream")
		}
	case <-time.After(time.Second):
		t.Fatal("downstream keepalives must not extend upstream idle deadline")
	}
}

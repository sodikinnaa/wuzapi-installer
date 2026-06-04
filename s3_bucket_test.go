package main

import (
	"sync"
	"testing"
)

// TestBucketFor covers the S3 config read used when building media metadata: it
// returns the bucket when configured and an empty string (never a nil panic)
// when there is no config.
func TestBucketFor(t *testing.T) {
	m := &S3Manager{configs: map[string]*S3Config{}}

	if got := m.bucketFor("nobody"); got != "" {
		t.Errorf("no config: got %q; want empty string", got)
	}

	m.configs["u1"] = &S3Config{Bucket: "my-bucket"}
	if got := m.bucketFor("u1"); got != "my-bucket" {
		t.Errorf("got %q; want %q", got, "my-bucket")
	}
}

// TestBucketForConcurrent runs bucketFor against concurrent writers. The unlocked
// map read this replaced raced with config updates: Go's runtime flags it with
// "concurrent map read and map write" (and the race detector confirms it). The
// locked read passes.
func TestBucketForConcurrent(t *testing.T) {
	m := &S3Manager{configs: map[string]*S3Config{}}
	var wg sync.WaitGroup
	for i := 0; i < 100; i++ {
		wg.Add(2)
		go func() {
			defer wg.Done()
			_ = m.bucketFor("u1")
		}()
		go func() {
			defer wg.Done()
			m.mu.Lock()
			m.configs["u1"] = &S3Config{Bucket: "b"}
			m.mu.Unlock()
		}()
	}
	wg.Wait()
}

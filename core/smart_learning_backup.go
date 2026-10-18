package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/metacubex/bbolt"
	"github.com/metacubex/mihomo/component/profile/cachefile"
	C "github.com/metacubex/mihomo/constant"
)

// exportSmartLearningSnapshot creates a consistent read-only snapshot of ONLY
// the Smart learning bucket. Copying an open cache.db would race bbolt writes,
// and bundling the whole cache would expose unrelated profile metadata.
// Caller MUST delete the returned temporary file after attaching it to an
// explicitly requested local backup. Never upload it in automatic WebDAV.
func exportSmartLearningSnapshot() (string, error) {
	cache := cachefile.Cache()
	if cache == nil || cache.DB == nil {
		return "", fmt.Errorf("learning database unavailable")
	}
	temp, err := os.CreateTemp(C.Path.HomeDir(), ".bettbox-learning-export-*.db")
	if err != nil { return "", err }
	path := temp.Name()
	if err := temp.Close(); err != nil {
		os.Remove(path)
		return "", err
	}
	if err := os.Chmod(path, 0o600); err != nil {
		os.Remove(path)
		return "", err
	}
	target, err := bbolt.Open(path, 0o600, nil)
	if err != nil { os.Remove(path); return "", err }
	success := false
	defer func() {
		_ = target.Close()
		if !success { _ = os.Remove(path) }
	}()
	err = cache.DB.View(func(read *bbolt.Tx) error {
		source := read.Bucket([]byte("smart_stats"))
		if source == nil { return fmt.Errorf("no Smart learning records") }
		_ = source
		return target.Update(func(write *bbolt.Tx) error {
			return copySmartLearningRecords(read, write)
		})
	})
	if err != nil { return "", err }
	// Snapshot must be fully closed before Dart opens it for ZIP compression.
	if err := target.Close(); err != nil { return "", err }
	success = true
	return filepath.Clean(path), nil
}


const pendingLearningFilename = ".bettbox-smart-learning-pending.db"

// copySmartLearningRecords is used by export and import and enforces that
// neither operation serializes unrelated cache DB buckets.
func copySmartLearningRecords(src, dst *bbolt.Tx) error {
	source := src.Bucket([]byte("smart_stats"))
	if source == nil { return fmt.Errorf("no Smart learning bucket") }
	target, err := dst.CreateBucketIfNotExists([]byte("smart_stats"))
	if err != nil { return err }
	return source.ForEach(func(key, value []byte) error {
		if !strings.HasPrefix(string(key), "smart/") {
			return fmt.Errorf("unexpected Smart learning key")
		}
		if len(value) > 1<<20 {
			return fmt.Errorf("Smart learning record too large")
		}
		return target.Put(key, value)
	})
}

// Applied once, before Smart groups load and cache their online students.
// The UI stages an explicitly restored snapshot; it must never overwrite
// cache.db while that database is open or an active Smart group is learning.
func restorePendingSmartLearning() error {
	path := filepath.Join(C.Path.HomeDir(), pendingLearningFilename)
	info, err := os.Stat(path)
	if os.IsNotExist(err) { return nil }
	if err != nil { return err }
	if !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > 512<<20 {
		return fmt.Errorf("invalid pending Smart learning snapshot")
	}
	source, err := bbolt.Open(path, 0o600,
		&bbolt.Options{ReadOnly: true, Timeout: time.Second})
	if err != nil { return fmt.Errorf("open Smart learning restore: %w", err) }
	defer source.Close()
	target := cachefile.Cache()
	if target == nil || target.DB == nil { return fmt.Errorf("core cache DB unavailable") }
	err = source.View(func(read *bbolt.Tx) error {
		return target.DB.Update(func(write *bbolt.Tx) error {
			return copySmartLearningRecords(read, write)
		})
	})
	if err != nil { return fmt.Errorf("restore Smart learning: %w", err) }
	return os.Remove(path)
}

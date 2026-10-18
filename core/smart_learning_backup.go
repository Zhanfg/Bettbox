package main

import (
	"fmt"
	"os"
	"path/filepath"

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
		return target.Update(func(write *bbolt.Tx) error {
			dest, err := write.CreateBucketIfNotExists([]byte("smart_stats"))
			if err != nil { return err }
			return source.ForEach(func(key, value []byte) error {
				if len(key) < 6 || string(key[:6]) != "smart/" {
					return fmt.Errorf("unexpected Smart learning key")
				}
				return dest.Put(key, value)
			})
		})
	})
	if err != nil { return "", err }
	// Snapshot must be fully closed before Dart opens it for ZIP compression.
	if err := target.Close(); err != nil { return "", err }
	success = true
	return filepath.Clean(path), nil
}

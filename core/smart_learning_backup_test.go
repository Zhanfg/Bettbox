package main

import (
	"path/filepath"
	"testing"

	"github.com/metacubex/bbolt"
)

func TestSmartLearningBackupContainsOnlyPrivateScopedLearning(t *testing.T) {
	open := func(name string) *bbolt.DB {
		t.Helper()
		d,err := bbolt.Open(filepath.Join(t.TempDir(), name),0o600,nil)
		if err != nil { t.Fatal(err) }
		return d
	}
	src:=open("source.db")
	defer src.Close()
	dst:=open("snapshot.db")
	defer dst.Close()
	err:=src.Update(func(tx *bbolt.Tx) error {
		learning,err:=tx.CreateBucketIfNotExists([]byte("smart_stats"))
		if err != nil { return err }
		if err=learning.Put([]byte("smart/stats/config:bettbox-alpha/Auto/example/node1"),[]byte("{\"success\":42}")); err!=nil { return err }
		unrelated,err:=tx.CreateBucketIfNotExists([]byte("selected"))
		if err != nil { return err }
		return unrelated.Put([]byte("secret-subscription"),[]byte("private-record"))
	})
	if err!=nil { t.Fatal(err) }
	err=src.View(func(read *bbolt.Tx) error {
		return dst.Update(func(write *bbolt.Tx) error {
			return copySmartLearningRecords(read,write)
		})
	})
	if err!=nil { t.Fatal(err) }
	err=dst.View(func(tx *bbolt.Tx) error {
		if tx.Bucket([]byte("selected"))!=nil {
			t.Fatal("non-learning cache data was copied")
		}
		b:=tx.Bucket([]byte("smart_stats"))
		if b==nil { t.Fatal("missing Smart learning records") }
		key:=[]byte("smart/stats/config:bettbox-alpha/Auto/example/node1")
		if string(b.Get(key))!="{\"success\":42}" {
			t.Fatal("learning snapshot lost scoped record")
		}
		return nil
	})
	if err!=nil { t.Fatal(err) }

	// The identical copy function is used at core startup for pending
	// backup import. Verify records survive both snapshot and restoration.
	restored := open("restored.db")
	defer restored.Close()
	if err:=dst.View(func(read *bbolt.Tx) error {
		return restored.Update(func(write *bbolt.Tx) error {
			return copySmartLearningRecords(read,write)
		})
	}); err!=nil { t.Fatal(err) }
	if err:=restored.View(func(tx *bbolt.Tx) error {
		b := tx.Bucket([]byte("smart_stats"))
		if b == nil { t.Fatal("no restored learning bucket") }
		got:=string(b.Get([]byte("smart/stats/config:bettbox-alpha/Auto/example/node1")))
		if got != "{\\"success\\":42}" {
			t.Fatalf("restored learning record mismatch: %s",got)
		}
		return nil
	}); err!=nil { t.Fatal(err) }
}

func TestSmartLearningBackupRejectsUnexpectedKeys(t *testing.T) {
	dir:=t.TempDir()
	src,err:=bbolt.Open(filepath.Join(dir,"src.db"),0o600,nil)
	if err!=nil { t.Fatal(err) }
	defer src.Close()
	dst,err:=bbolt.Open(filepath.Join(dir,"dst.db"),0o600,nil)
	if err!=nil { t.Fatal(err) }
	defer dst.Close()
	if err:=src.Update(func(tx *bbolt.Tx) error {
		b,e:=tx.CreateBucketIfNotExists([]byte("smart_stats"))
		if e!=nil {return e}
		return b.Put([]byte("../private"),[]byte("unsafe"))
	}); err!=nil {t.Fatal(err)}
	if err:=src.View(func(read *bbolt.Tx) error {
		return dst.Update(func(write *bbolt.Tx) error {
			return copySmartLearningRecords(read,write)
		})
	});err==nil {
		t.Fatal("unexpected keys were silently imported")
	}
}

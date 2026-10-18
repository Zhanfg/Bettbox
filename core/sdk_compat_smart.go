//go:build bettbox_smart_portable

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/component/profile/cachefile"
	"github.com/metacubex/mihomo/component/updater"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/listener"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

func getSubscriptionInfoCompat(psp *provider.ProxySetProvider) *provider.SubscriptionInfo {
	raw := cachefile.Cache().GetSubscriptionInfo(psp.Name())
	if raw == "" {
		return nil
	}
	return provider.NewSubscriptionInfo(raw)
}

// Smart V9 deliberately keeps DefaultTestURL immutable. Bettbox already
// rewrites every proxy-group URL when OverrideTestUrl is true (the app default),
// so no global mutable default is needed in the portable profile.
func setDefaultTestURLCompat(_ string) {}

func trafficNowCompat(_ bool) (int64, int64) {
	return statistic.DefaultManager.Now()
}

func trafficTotalCompat(_ bool) (int64, int64) {
	return statistic.DefaultManager.Total()
}

func stopListenersCompat() {
	listener.ReCreateHTTP(0, tunnel.Tunnel)
	listener.ReCreateSocks(0, tunnel.Tunnel)
	listener.ReCreateRedir(0, tunnel.Tunnel)
	listener.ReCreateTProxy(0, tunnel.Tunnel)
	listener.ReCreateMixed(0, tunnel.Tunnel)
	listener.ReCreateShadowSocks("", tunnel.Tunnel)
	listener.ReCreateVmess("", tunnel.Tunnel)
	listener.ReCreateTuic(LC.TuicServer{}, tunnel.Tunnel)
	listener.PatchTunnel(nil, tunnel.Tunnel)
	listener.PatchInboundListeners(map[string]C.InboundListener{}, tunnel.Tunnel, true)
	listener.Cleanup()
}

func mirrorUpdatedGeoFile(source, target string) error {
	if source == "" {
		return fmt.Errorf("updated geo source path is empty")
	}
	source = filepath.Clean(source)
	target = filepath.Clean(target)
	if source == target {
		return nil
	}
	data, err := os.ReadFile(source)
	if err != nil {
		return fmt.Errorf("read updated geo file: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return fmt.Errorf("create geo target directory: %w", err)
	}
	if err := os.WriteFile(target, data, 0o644); err != nil {
		return fmt.Errorf("write geo target file: %w", err)
	}
	return nil
}

func updateMMDBWithPathCompat(path string) error {
	if err := updater.UpdateMMDB(); err != nil {
		return err
	}
	return mirrorUpdatedGeoFile(C.Path.MMDB(), path)
}

func updateASNWithPathCompat(path string) error {
	if err := updater.UpdateASN(); err != nil {
		return err
	}
	return mirrorUpdatedGeoFile(C.Path.ASN(), path)
}

func updateGeoSiteWithPathCompat(path string) error {
	if err := updater.UpdateGeoSite(); err != nil {
		return err
	}
	return mirrorUpdatedGeoFile(C.Path.GeoSite(), path)
}

// These UI event hooks came from Bettbox's embedded Mihomo patch-set. Smart
// portable keeps them behind this facade so the data-plane core stays pristine.
// Dedicated low-overhead lifecycle events will replace these no-ops after the
// transport/ABI stability gates are green.
// Notify the original Bettbox UI about both explicit and scheduled probes.
// A bounded worker keeps potentially slow Flutter IPC outside health checks.
type smartDelayEvent struct {
	url, name string
	delay     uint16
}

var (
	smartDelayEvents  = make(chan smartDelayEvent, 512)
	smartDelayWorker  sync.Once
	smartDelayDropped atomic.Uint64
)

func setURLTestHookCompat(fn func(url, name string, delay uint16)) {
	smartDelayWorker.Do(func() {
		go func() {
			for event := range smartDelayEvents {
				fn(event.url, event.name, event.delay)
			}
		}()
	})
	adapter.SetURLTestHook(func(url, name string, delay uint16) {
		select {
		case smartDelayEvents <- smartDelayEvent{url: url, name: name, delay: delay}:
		default:
			n := smartDelayDropped.Add(1)
			if n == 1 || n%1024 == 0 {
				log.Warnln("[Bettbox] delay notification queue saturated; dropped=%d", n)
			}
		}
	})
}
// A bounded worker preserves Bettbox request history/notifications while
// keeping the Smart tracker join path independent of slow Flutter IPC. Events
// are observed on connection creation (not on each byte of traffic).
var (
	smartRequestEvents  = make(chan statistic.Tracker, 1024)
	smartRequestWorker  sync.Once
	smartRequestDropped atomic.Uint64
)

func setRequestNotifyCompat(fn func(statistic.Tracker)) {
	smartRequestWorker.Do(func() {
		go func() {
			for tracker := range smartRequestEvents {
				fn(tracker)
			}
		}()
	})
	statistic.SetRequestNotifyHook(func(tracker statistic.Tracker) {
		select {
		case smartRequestEvents <- tracker:
		default:
			n := smartRequestDropped.Add(1)
			if n == 1 || n%1024 == 0 {
				log.Warnln("[Bettbox] request event queue saturated; dropped=%d", n)
			}
		}
	})
}
var (
	smartProviderEvents  = make(chan string, 256)
	smartProviderWorker  sync.Once
	smartProviderDropped atomic.Uint64
)

func setProviderLoadedHookCompat(fn func(string)) {
	smartProviderWorker.Do(func() {
		go func() {
			for name := range smartProviderEvents {
				fn(name)
			}
		}()
	})
	provider.SetProviderUpdateHook(func(name string) {
		select {
		case smartProviderEvents <- name:
		default:
			n := smartProviderDropped.Add(1)
			if n == 1 || n%1024 == 0 {
				log.Warnln("[Bettbox] provider notification queue saturated; dropped=%d", n)
			}
		}
	})
}

 
// Bettbox's explicit test and provider-update operations still need UI events
// even though upstream Smart no longer exposes the legacy push callbacks.
// The native Smart observer emits these events for both explicit and
// background operations. Avoid duplicates from Bettbox's manual action path.
func notifyDelayResultCompat(_ *Delay) {}
func notifyProviderUpdatedCompat(_ string) {}

func updateLgbmModelCompat() error {
	return updater.UpdateLgbmModelDatabase()
}

func restoreBundledLiteCompat() error {
	return updater.RestoreBundledLiteModel()
}

func installSmartModelPresetCompat(name string) error {
	return updater.InstallSmartModelPreset(name)
}

func importSmartModelCompat(path string) error {
	return updater.ImportSmartModelFile(path)
}

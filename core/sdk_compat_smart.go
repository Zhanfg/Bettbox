//go:build bettbox_smart_portable

package main

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/component/profile/cachefile"
	"github.com/metacubex/mihomo/component/updater"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/listener"
	LC "github.com/metacubex/mihomo/listener/config"
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
func setURLTestHookCompat(_ func(url, name string, delay uint16)) {}
func setRequestNotifyCompat(_ func(statistic.Tracker)) {}
func setProviderLoadedHookCompat(_ func(string)) {}

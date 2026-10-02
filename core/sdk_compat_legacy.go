//go:build !bettbox_smart_portable

package main

import (
	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/component/updater"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/listener"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

func getSubscriptionInfoCompat(psp *provider.ProxySetProvider) *provider.SubscriptionInfo {
	return psp.GetSubscriptionInfo()
}

func setDefaultTestURLCompat(url string) {
	constant.DefaultTestURL = url
}

func trafficNowCompat(onlyProxy bool) (int64, int64) {
	return statistic.DefaultManager.NowTraffic(onlyProxy)
}

func trafficTotalCompat(onlyProxy bool) (int64, int64) {
	return statistic.DefaultManager.TotalTraffic(onlyProxy)
}

func stopListenersCompat() {
	listener.StopListener()
}

func updateMMDBWithPathCompat(path string) error {
	return updater.UpdateMMDBWithPath(path)
}

func updateASNWithPathCompat(path string) error {
	return updater.UpdateASNWithPath(path)
}

func updateGeoSiteWithPathCompat(path string) error {
	return updater.UpdateGeoSiteWithPath(path)
}

func setURLTestHookCompat(fn func(url, name string, delay uint16)) {
	adapter.UrlTestHook = fn
}

func setRequestNotifyCompat(fn func(statistic.Tracker)) {
	statistic.DefaultRequestNotify = fn
}

func setProviderLoadedHookCompat(fn func(string)) {
	executor.DefaultProviderLoadedHook = fn
}

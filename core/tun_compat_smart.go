//go:build bettbox_smart_portable

package main

import LC "github.com/metacubex/mihomo/listener/config"

func setTunCongestionController(_ *LC.Tun, _ string) {}

func getTunCongestionController(_ LC.Tun) string {
	return ""
}

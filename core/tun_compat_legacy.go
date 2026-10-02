//go:build !bettbox_smart_portable

package main

import LC "github.com/metacubex/mihomo/listener/config"

func setTunCongestionController(tun *LC.Tun, value string) {
	tun.CongestionController = value
}

func getTunCongestionController(tun LC.Tun) string {
	return tun.CongestionController
}

//go:build android && cgo && !bettbox_smart_portable

package tun

import LC "github.com/metacubex/mihomo/listener/config"

func setTunCongestionController(tun *LC.Tun, value string) {
	tun.CongestionController = value
}

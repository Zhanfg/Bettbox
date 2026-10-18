//go:build bettbox_smart_portable

package main

import (
    "encoding/json"

    "github.com/metacubex/mihomo/adapter/outboundgroup"
    "github.com/metacubex/mihomo/component/profile/cachefile"
    "github.com/metacubex/mihomo/tunnel"
)

// Return the native Smart node weights without opening a public HTTP control port.
func handleGetSmartRankings(name string) string {
    runLock.Lock()
    defer runLock.Unlock()

    fail := func(reason string) string {
        data, _ := json.Marshal(map[string]any{"weights": []any{}, "error": reason})
        return string(data)
    }
    if !isInit {
        return fail("core not initialized")
    }
    proxy, exists := tunnel.Proxies()[name]
    if !exists {
        return fail("Smart group not found")
    }
    smartGroup, ok := proxy.Adapter().(*outboundgroup.Smart)
    if !ok {
        return fail("not a Smart group")
    }
    store := cachefile.GetSmartStore()
    if store == nil {
        return fail("Smart ranking cache unavailable")
    }
    ranking, err := store.GetNodeWeightRankingCache(
        smartGroup.Name(), smartGroup.GetConfigFilename(),
    )
    if err != nil {
        return fail(err.Error())
    }
    if ranking == nil {
        return `{"weights":[]}`
    }
    data, err := json.Marshal(map[string]any{
        "weights": ranking.Result,
        "lastUpdated": ranking.LastUpdated,
    })
    if err != nil {
        return fail("cannot encode Smart ranking")
    }
    return string(data)
}

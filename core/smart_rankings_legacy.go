//go:build !bettbox_smart_portable

package main

// A compatible legacy core does not expose Mihono Smart's rank cache.
func handleGetSmartRankings(_ string) string {
    return `{"weights":[],"error":"Smart is unavailable in this core"}`
}

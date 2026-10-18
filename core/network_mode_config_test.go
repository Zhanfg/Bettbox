package main

import (
	"encoding/json"
	"strings"
	"testing"

	LC "github.com/metacubex/mihomo/listener/config"
)

func TestTunUpdateSchemaKeepsPerformanceAndCompatibilityFields(t *testing.T) {
	var request UpdateParams
	err := json.Unmarshal([]byte(`{
		"mixed-port":7890,
		"tun":{
			"enable":true,
			"mtu":4064,
			"endpoint-independent-nat":true,
			"stack":"mixed"
		}
	}`), &request)
	if err != nil { t.Fatal(err) }
	if request.Tun == nil || request.Tun.MTU == nil ||
		*request.Tun.MTU != 4064 ||
		request.Tun.EndpointIndependentNat == nil ||
		!*request.Tun.EndpointIndependentNat {
		t.Fatalf("TUN settings were silently dropped: %#v", request.Tun)
	}
}

func TestTUNListenerStableAcrossControlOnlySettings(t *testing.T) {
	original := LC.Tun{Enable: true, Device: "Bettbox", MTU: 9000, AutoRoute: true}
	tests := []struct {
		name string
		next LC.Tun
		mixedPort int
		allowLan bool
		iface string
		want bool
	}{
		{"unchanged settings",original,7890,false,"",false},
		{"changing MTU",func() LC.Tun { c:=original; c.MTU=4064; return c }(),7890,false,"",true},
		{"changing TUN activation",func() LC.Tun { c:=original; c.Enable=false; return c }(),7890,false,"",true},
		{"changing endpoint-independent NAT",func() LC.Tun { c:=original; c.EndpointIndependentNat=true; return c }(),7890,false,"",true},
		{"changing mixed-port",original,7891,false,"",true},
		{"changing LAN binding",original,7890,true,"",true},
		{"changing egress interface",original,7890,false,"Wi-Fi",true},
	}
	for _, tt := range tests {
		t.Run(tt.name,func(t *testing.T) {
			got := requiresListenerRefresh(original,tt.next,7890,tt.mixedPort,
				false,tt.allowLan,"",tt.iface)
			if got != tt.want { t.Fatalf("refresh=%v, wanted %v",got,tt.want) }
		})
	}
}

func TestTunSchemaRejectsUnsupportedType(t *testing.T) {
	var req UpdateParams
	err:=json.Unmarshal([]byte(`{"tun":{"mtu":"jumbo"}}`),&req)
	if err==nil || !strings.Contains(err.Error(),"mtu") {
		t.Fatalf("expected invalid MTU type error, got %v",err)
	}
}

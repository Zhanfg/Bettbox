#include "proxy_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include <WinInet.h>
#include <Ras.h>
#include <RasError.h>
#include <vector>
#include <array>
#include <functional>
#include <iostream>

#pragma comment(lib, "wininet")
#pragma comment(lib, "Rasapi32")

// For getPlatformVersion; remove unless needed for your plugin implementation.
#include <VersionHelpers.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <sstream>

// Only the Windows Flutter plugin may mutate interactive-user WinINet state.
// Track ownership so a session shutdown cannot clear an unrelated user proxy.
namespace {
bool proxy_owned_by_this_process = false;

bool apply_connection_options(
    const wchar_t* connection,
    DWORD flags,
    const std::wstring* server,
    const std::wstring* bypass) {
  std::array<INTERNET_PER_CONN_OPTION, 3> options{};
  options[0].dwOption = INTERNET_PER_CONN_FLAGS;
  options[0].Value.dwValue = flags;
  DWORD count = 1;
  if (server != nullptr && bypass != nullptr) {
    options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
    options[1].Value.pszValue = const_cast<LPWSTR>(server->c_str());
    options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
    options[2].Value.pszValue = const_cast<LPWSTR>(bypass->c_str());
    count = 3;
  }
  INTERNET_PER_CONN_OPTION_LIST list{};
  list.dwSize = sizeof(list);
  list.pszConnection = const_cast<LPWSTR>(connection);
  list.dwOptionCount = count;
  list.pOptions = options.data();
  return InternetSetOption(
      nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION, &list, sizeof(list)) != FALSE;
}

bool for_each_ras_entry(const std::function<bool(const wchar_t*)>& op) {
  RASENTRYNAME initial{};
  initial.dwSize = sizeof(initial);
  DWORD needed = sizeof(initial);
  DWORD count = 0;
  DWORD result = RasEnumEntries(nullptr, nullptr, &initial, &needed, &count);
  std::vector<RASENTRYNAME> entries;
  const RASENTRYNAME* data = &initial;
  if (result == ERROR_BUFFER_TOO_SMALL) {
    entries.resize((needed + sizeof(RASENTRYNAME) - 1) / sizeof(RASENTRYNAME));
    if (entries.empty()) return false;
    entries[0].dwSize = sizeof(RASENTRYNAME);
    result = RasEnumEntries(nullptr, nullptr, entries.data(), &needed, &count);
    data = entries.data();
  }
  if (result != ERROR_SUCCESS) return false;
  bool success = true;
  for (DWORD index = 0; index < count; ++index) {
    // Keep processing other connection entries if one Windows API call fails.
    if (!op(data[index].szEntryName)) success = false;
  }
  return success;
}

void broadcast_proxy_changed() {
  InternetSetOption(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0);
  InternetSetOption(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0);
}
}  // namespace

bool startProxy(const int port, const flutter::EncodableList& bypassDomain) {
  if (port <= 0 || port > 65535) return false;
  const std::wstring server = L"127.0.0.1:" + std::to_wstring(port);
  std::wstring bypass = L"<local>";
  for (const auto& domain : bypassDomain) {
    const auto* value = std::get_if<std::string>(&domain);
    if (!value) return false;
    // Proxy bypass patterns are typically ASCII DNS names. Reject malformed
    // encodings rather than dereferencing mismatched temporary iterators.
    bypass += L";";
    bypass.append(value->begin(), value->end());
  }
  const DWORD flags = PROXY_TYPE_DIRECT | PROXY_TYPE_PROXY;
  const bool lan = apply_connection_options(nullptr, flags, &server, &bypass);
  if (!lan) return false;
  proxy_owned_by_this_process = true;
  const bool ras = for_each_ras_entry([&](const wchar_t* name) {
    return apply_connection_options(name, flags, &server, &bypass);
  });
  broadcast_proxy_changed();
  return ras;
}

bool stopProxy() {
  if (!proxy_owned_by_this_process) return true;
  const bool lan = apply_connection_options(
      nullptr, PROXY_TYPE_DIRECT, nullptr, nullptr);
  const bool ras = for_each_ras_entry([&](const wchar_t* name) {
    return apply_connection_options(
        name, PROXY_TYPE_DIRECT, nullptr, nullptr);
  });
  if (lan && ras) proxy_owned_by_this_process = false;
  broadcast_proxy_changed();
  return lan && ras;
}

namespace proxy
{

  // static
  void ProxyPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarWindows *registrar)
  {
    auto channel =
        std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            registrar->messenger(), "proxy",
            &flutter::StandardMethodCodec::GetInstance());

    auto plugin = std::make_unique<ProxyPlugin>(registrar);

    channel->SetMethodCallHandler(
        [plugin_pointer = plugin.get()](const auto &call, auto result)
        {
          plugin_pointer->HandleMethodCall(call, std::move(result));
        });

    registrar->AddPlugin(std::move(plugin));
  }

  ProxyPlugin::ProxyPlugin(flutter::PluginRegistrarWindows *registrar)
      : registrar(registrar) {
    window_proc_id = registrar->RegisterTopLevelWindowProcDelegate(
        [this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
          return HandleWindowProc(hwnd, message, wparam, lparam);
        });
  }

  ProxyPlugin::~ProxyPlugin() {
    if (registrar && window_proc_id != -1) {
      registrar->UnregisterTopLevelWindowProcDelegate(window_proc_id);
    }
  }

  std::optional<LRESULT> ProxyPlugin::HandleWindowProc(
      HWND hwnd,
      UINT message,
      WPARAM wparam,
      LPARAM lparam) {
    if (message == WM_ENDSESSION) {
      if (wparam == TRUE && proxy_owned_by_this_process) {
        stopProxy();
      }
    }
    return std::nullopt;
  }

  void ProxyPlugin::HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result)
  {
    if (method_call.method_name().compare("StopProxy") == 0)
    {
      result->Success(stopProxy());
    }
    else if (method_call.method_name().compare("StartProxy") == 0)
    {
      auto *arguments = std::get_if<flutter::EncodableMap>(method_call.arguments());
      auto port = std::get<int>(arguments->at(flutter::EncodableValue("port")));
      auto bypassDomain = std::get<flutter::EncodableList>(arguments->at(flutter::EncodableValue("bypassDomain")));
      result->Success(startProxy(port, bypassDomain));
    }
    else
    {
      result->NotImplemented();
    }
  }
} // namespace proxy

#include "proxy_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include <WinInet.h>
#include <Ras.h>
#include <RasError.h>
#include <vector>
#include <array>
#include <map>
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

// WinINet user proxy settings are shared with other Windows applications.
// Treat the lifecycle as a reversible transaction; never reset settings
// which no longer match the values this process applied.
namespace {
struct ProxySettings {
  std::wstring connection;
  DWORD flags = PROXY_TYPE_DIRECT;
  std::wstring server;
  std::wstring bypass;
  std::wstring auto_config_url;
};

std::map<std::wstring, ProxySettings> original_settings;
bool proxy_owned_by_this_process = false;
std::wstring owned_server;
std::wstring owned_bypass;

bool read_connection(const std::wstring& name, ProxySettings* snapshot) {
  if (!snapshot) return false;
  std::array<INTERNET_PER_CONN_OPTION, 4> options{};
  options[0].dwOption = INTERNET_PER_CONN_FLAGS;
  options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
  options[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
  INTERNET_PER_CONN_OPTION_LIST list{};
  list.dwSize = sizeof(list);
  list.pszConnection = name.empty() ? nullptr : const_cast<LPWSTR>(name.c_str());
  list.dwOptionCount = static_cast<DWORD>(options.size());
  list.pOptions = options.data();
  DWORD size = sizeof(list);
  if (InternetQueryOption(
      nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION, &list, &size) == FALSE) {
    // The caller must not change a Windows proxy without an original snapshot.
    for (int i = 1; i < 4; ++i) {
      if (options[i].Value.pszValue) GlobalFree(options[i].Value.pszValue);
    }
    return false;
  }
  snapshot->connection = name;
  snapshot->flags = options[0].Value.dwValue;
  if (options[1].Value.pszValue)
    snapshot->server = options[1].Value.pszValue;
  if (options[2].Value.pszValue)
    snapshot->bypass = options[2].Value.pszValue;
  if (options[3].Value.pszValue)
    snapshot->auto_config_url = options[3].Value.pszValue;
  for (int i = 1; i < 4; ++i) {
    if (options[i].Value.pszValue) GlobalFree(options[i].Value.pszValue);
  }
  return true;
}

bool write_connection(const ProxySettings& value) {
  std::array<INTERNET_PER_CONN_OPTION, 4> options{};
  options[0].dwOption = INTERNET_PER_CONN_FLAGS;
  options[0].Value.dwValue = value.flags;
  options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  options[1].Value.pszValue = const_cast<LPWSTR>(value.server.c_str());
  options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
  options[2].Value.pszValue = const_cast<LPWSTR>(value.bypass.c_str());
  options[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
  options[3].Value.pszValue = const_cast<LPWSTR>(value.auto_config_url.c_str());
  INTERNET_PER_CONN_OPTION_LIST list{};
  list.dwSize = sizeof(list);
  list.pszConnection = value.connection.empty()
      ? nullptr : const_cast<LPWSTR>(value.connection.c_str());
  list.dwOptionCount = static_cast<DWORD>(options.size());
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
  for (DWORD i = 0; i < count; ++i) {
    if (!op(data[i].szEntryName)) success = false;
  }
  return success;
}

void broadcast_proxy_changed() {
  InternetSetOption(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0);
  InternetSetOption(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0);
}

bool current_is_ours(const ProxySettings& current) {
  return (current.flags & PROXY_TYPE_PROXY) &&
      current.server == owned_server &&
      current.bypass == owned_bypass;
}
}  // namespace

bool startProxy(const int port, const flutter::EncodableList& bypassDomain) {
  if (port <= 0 || port > 65535) return false;
  const std::wstring server = L"127.0.0.1:" + std::to_wstring(port);
  std::wstring bypass = L"<local>";
  for (const auto& domain : bypassDomain) {
    const auto* value = std::get_if<std::string>(&domain);
    if (!value) return false;
    bypass += L";";
    bypass.append(value->begin(), value->end());
  }
  if (proxy_owned_by_this_process &&
      server == owned_server && bypass == owned_bypass) return true;

  // Snapshot *every* affected Windows LAN/RAS entry BEFORE touching any.
  std::vector<std::wstring> names{L""};
  if (!for_each_ras_entry([&](const wchar_t* name) {
    names.emplace_back(name);
    return true;
  })) return false;
  std::vector<ProxySettings> before;
  before.reserve(names.size());
  for (const auto& name : names) {
    ProxySettings original{};
    if (!read_connection(name, &original)) return false;
    // Preserve another application's live changes while already managing
    // the system proxy. We must not reassert our own settings over them.
    if (proxy_owned_by_this_process && original_settings.count(name) &&
        !current_is_ours(original)) return false;
    before.push_back(std::move(original));
  }

  std::size_t applied = 0;
  for (const auto& previous : before) {
    ProxySettings desired = previous;
    desired.flags = PROXY_TYPE_DIRECT | PROXY_TYPE_PROXY;
    desired.server = server;
    desired.bypass = bypass;
    desired.auto_config_url.clear();
    if (!write_connection(desired)) {
      // Roll back only entries we successfully changed; no partial takeover.
      for (std::size_t i = 0; i < applied; ++i)
        write_connection(before[i]);
      if (applied) broadcast_proxy_changed();
      return false;
    }
    ++applied;
  }
  for (const auto& previous : before) {
    if (!original_settings.count(previous.connection)) {
      original_settings.emplace(previous.connection, previous);
    }
  }
  owned_server = server;
  owned_bypass = bypass;
  proxy_owned_by_this_process = true;
  broadcast_proxy_changed();
  return true;
}

bool stopProxy() {
  if (!proxy_owned_by_this_process) return true;
  bool success = true;
  bool changed = false;
  for (const auto& [name, original] : original_settings) {
    ProxySettings current{};
    if (!read_connection(name, &current)) {
      success = false;
      continue;
    }
    // User/third-party changes take precedence over app-owned values.
    if (!current_is_ours(current)) continue;
    if (!write_connection(original)) {
      success = false;
      continue;
    }
    changed = true;
  }
  if (success) {
    original_settings.clear();
    owned_server.clear();
    owned_bypass.clear();
    proxy_owned_by_this_process = false;
  }
  if (changed) broadcast_proxy_changed();
  return success;
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

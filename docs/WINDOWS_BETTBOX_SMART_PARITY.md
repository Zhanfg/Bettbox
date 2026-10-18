# Windows Bettbox × Smart V11 — 原版功能兼容性门槛

> **原则：原版 Bettbox 是产品基线，Smart 是增量能力，不是精简版替换。** 不允许以“程序启动”或“节点可连通”替代原有功能回归验证。本文件随代码维护；未经过 Windows 真实运行测试的条目一律不可标记为通过。

## 基线

- Bettbox 原有 Flutter UI、Rust HelperService、Windows 托盘和系统集成逻辑保持原架构。
- 可选 Smart 内核采用 `smart-core.lock.json` 锁定的自有 Mihomo 源码，后端差异通过 `core/sdk_compat_*.go` 或单独 API 消化，不散落在页面逻辑中。
- 原版相关参考：`Zhanfg/Bettbox@main`，原作者上游 `appshubcc/Bettbox`；需在稳定发布前对齐上游版本和遗漏功能。
- Smart UI：已有代理组界面上新增策略诊断、真实权重、国家/ASN/IPv4/IPv6 与学习开关；不能替代传统 Selector / URLTest / Fallback / LoadBalance 操作。

## 按功能审查与放行状态

| 原 Bettbox 能力 | 当前代码情况 | Windows 放行状态 |
|---|---|---|
| 配置文件/远程订阅导入、更新、切换 | 原页面和数据层保留；Smart 覆盖项按 Profile 保存，不改写原订阅 | **待端到端测试** |
| JS 覆写脚本/UI 适配与规则选择 | 原编辑器与脚本入口保留 | **待回归测试** |
| 手动节点、URLTest、Fallback、LoadBalance、GLOBAL | 传统组逻辑保留；Smart 作为新 GroupType，支持手动 pin / 自动策略切换 | **待端到端测试** |
| 节点延迟测试与周期性健康检测消息 | 恢复 Smart 的 URLTest 完成 hook，通知适配层通过有界队列转发 | **核心 Go 测试通过；待 Windows UI 联调** |
| Provider 更新及自动订阅刷新通知 | 恢复代理集变更 hook；通知在锁释放后发送；兼容显式及后台更新 | **核心 Go 测试通过；待 UI 联调** |
| 请求历史与实时请求列表 | 恢复 tracker 创建 hook，单次连接通知，经有界队列转发；原日志最大 256 条 | **核心 Go 测试通过；待 UI 联调** |
| 连接列表/连接关闭/统计 | 原 IPC 与连接快照代码保留 | **待端到端测试** |
| 代理流量与累计流量、仅统计代理流量 | Smart 当前统计方法忽略 `OnlyStatisticsProxy` 参数 | **未达到功能等价，不可验收** |
| 系统代理、TUN、Windows HelperService、提权 | 原服务和 UI 保留，Smart 的 TUN 控制接口需实际验证 | **待 Windows 10/11 真机测试** |
| DNS、IPv4/IPv6、规则、嗅探、Fake-IP、QUIC 禁用 | 原配置页面与规则转换代码保留 | **待端到端测试** |
| 休眠/恢复、后台运行、托盘菜单、快捷键、自启 | 原页面和服务逻辑保留，已有模型及托盘测试加入 CI | **待 Windows 真机压力测试** |
| 内建 YAML 编辑、主题、仪表盘、备份/恢复、日志 | 页面和数据路径保留，部分 Dart 单测纳入 CI | **待完整回归测试** |
| Windows x64 Compatible CPU / Portable | 构建 CPU 兼容模式仍保留 Smart；CI 编译并打包便携 ZIP | **待成功构建与实际启动** |
| 原版 Windows 安装包签名与便利的权限处理 | 自有测试包尚未拥有原上游签名链与正式安装程序 | **未达到功能等价，不可作为稳定版发布** |

### 新增 Smart 功能，不侵占旧功能

- 每配置文件、每组独立设置：国家偏好 / ASN 偏好 / IP 族约束 / 自动 IP 族 / 采样率 / 专家模型。
- 展示 Smart 核心实际返回的路径观测、最终出口 IP/国家、网络 RTT/丢包与目标连接测量；未知数据明确显示未知，禁止填充模拟值。
- 核心 `/groups/{name}/weights` 相同来源的真实智能排名，经本地 IPC 读取而不暴露公网管理口。
- 原有代理组可临时转换为 Smart，本地保存先前的手动选择，允许完整撤销。
- 配置参数必须先由真实 Go 内核验证，失败回滚本地值；不能静默降级成传统策略组。

## 自动门槛

1. `Zhanfg/mihomo` 的 `Bettbox Parity Hooks`：`go test -race -count=1 ./adapter ./adapter/provider ./tunnel/statistic`。
2. `Zhanfg/Bettbox` 的 `Windows Smart V11 Preview`：原版 Bettbox 的 model/proxy/tray 相关 Flutter 测试 + Smart 契约测试 + 锁定 Smart 源码校验。
3. 真正 Windows Runner：Go 核心、Rust HelperService、Flutter 发布构建、unsigned portable ZIP 全部成功；必须实际检查文件存在。
4. Windows 10/11 交互测试：订阅导入/更新、不同组模式、规则/DNS 与 TUN 管理、系统代理/权限、休眠/网络切换/断网恢复、请求/Provider/测速推送。
5. 功能等价指标：订阅更新不能清除 Smart 覆盖与手动锁定；原版策略组和 JS UI 不允许因 Smart 报错；在断网、切网、后台等边界状态不能重复累积系统代理或虚拟网卡配置。

## 风险与限制

- 基础 Go 钩子只在连接注册、URL 测速完成、Provider 变更时触发，不在每个 TCP/UDP 包上额外做 UI 工作。
- 适配层使用有界队列；在极端高频事件负载下会记录丢弃计数。稳定版应评估事件无丢失语义或增加可恢复的查询接口。
- **仅统计代理流量**和**正式签名安装/自动权限体验**目前仍是不兼容项，不能宣称 100% 原版功能已经恢复。
- 本项目的 Draft PR 不应在上述条件达到之前合并或发布为稳定版。

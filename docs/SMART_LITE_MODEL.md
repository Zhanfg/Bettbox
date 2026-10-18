# Bettbox Windows: Smart Lite Model 资源与离线回退

## 设计约束

Lite Model **不是** 用来取代 Bettbox 原有 GeoSite/MMDB/ASN/MRS 资源，也不会替换常规的订阅、测速、TUN、流量/日志等功能。它是「资源」页面里的新增资源项。

- 活动模型：应用数据目录 `Model.bin`。用户更新或选择其他兼容模型时只修改这一份。
- 随包 Lite：安装资源 `assets/data/Model-Lite.bin`（Windows Flutter assets）。
- 本地独立回退：应用数据目录 `Model-Lite.bin`；每次启动校验，不让在线更新覆盖。
- 首次 Windows 初始化：**不依赖网络**，校验应用资源，安装回退副本。仅当活动模型不存在时才复制 Lite 为 `Model.bin`。
- 内核加载：优先现有活动模型；如果损坏或缺失，则校验并加载本地 Lite 回退；均不可用时才走已有模型下载/非 ML 算法降级路径。
- 在「资源」点击「Update model」：走 Bettbox 现有 `updateGeoData` IPC，调用 Smart `UpdateLgbmModelDatabase`，仅更新活动模型。
- 在「资源」点击「Restore bundled Lite」：走同一 IPC，Smart 校验并通过带回滚文件交换恢复活动模型，原来活动模型不在校验失败前删除。
- 所有在线模型仍必须由 Smart 的 LightGBM 模型解析器校验。不得把未知数据当成有效预测权重。

## 内置资产的确定来源

| 字段 | 值 |
|---|---|
| 名称 | vernesong/mihomo LightGBM-Model release · Model.bin |
| 类型 | 官方发布的小档（Lite）LightGBM 模型，不是自造的训练/蒸馏模型 |
| 来源 | https://github.com/vernesong/mihomo/releases/download/LightGBM-Model/Model.bin |
| 大小 | 9,345,218 字节 |
| SHA-256 | `23633022a815fb34e510befe1c176ba50af3ced48f08b172454f4cd6b8327788` |
| 版本冻结 | GitHub release 2026-08-26 的资产元数据 |

当前仓库**不存放**第三方 9.3 MB 二进制。Windows 构建时执行 `tool/fetch_lite_model.ps1` 下载并严格校验固定 SHA-256；下载失败/摘要变化一律停止构建，不能输出缺少回退模型的安装包。Flutter Windows release 输出目录也再次校验已嵌入的模型文件。

> 注意：回退模型只保证本地模型文件可用，不保证所有分流/节点策略都始终走模型。Smart 仍由 Greedy、Bandit、经验统计和严格路由约束共同决策。

## 测试门槛

1. Core Go：`go test -race ./adapter ./adapter/provider ./tunnel/statistic ./component/smart/lightgbm ./component/updater`。
2. Windows Runner：下载校验、Flutter 测试、Go 核心、Rust Helper、Flutter Release、ZIP 打包、在发布目录核对回退模型 SHA。
3. 真实 Windows：断网首启、旧版数据目录升级、自定义 Model.bin 不被覆写、模型更新失败仍能推理、活动模型损坏时回退、恢复 Lite 的事务回滚、卸载/便携模式路径。
4. 第一个可对外下载的 Windows 包必须内置 Lite，且以上测试合格才能标记为可用版。

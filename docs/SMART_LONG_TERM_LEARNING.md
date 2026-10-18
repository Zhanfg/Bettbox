# Windows Bettbox × Smart V11 — 持续学习和离线模型的职责

审查基线：`Zhanfg/mihomo:integration/bettbox-feature-parity@8d546db13ef65040c6be4549adef082ee77a147e`。

## 实际存在的长期学习链路

1. Smart 组观察真实流量连接完成后的 TCP / UDP 成功、失败、时延、吞吐、丢包、网络质量等（不是持续训练全部流量包）。
2. 使用本地 OnlineBandit（6 维）及 TinyRouter（极小残差头）将完成连接的反馈作为奖励，修正下一次相同/相关目标与路径的选路权重。
3. `StatsRecord` 序列化时带有 `bandit_tcp`、`bandit_udp`、`tiny_router_tcp`、`tiny_router_udp`。学习结果进入 Smart Store，并异步按批写入 bbolt 的 `smart_stats` bucket。
4. Bettbox 设置 `constant.Path.HomeDir` 到应用数据目录，持久文件是 `cache.db`：普通安装使用 Windows 应用支持目录；便携模式使用 `portable/`。配置文件重新加载不会主动清空这份数据库。
5. 维护任务按流量活动唤醒，不会因为程序空闲就持续做节点扫描；全局队列最多约 5 分钟周期强制刷盘，最后一个 Smart 组正常退出时再次刷新。
6. 连接指标会通过当前路由环境 epoch、置信度衰减等机制限制旧网络证据对新网络的影响，不把旧节点的成功率当成永久事实。

**自动长期学习 ≠ 离线训练 CSV**：`collectdata` 只表示是否将特征保存为 `smart_weight_data.csv` 供后续独立训练。默认关闭，防止额外磁盘写入和私密目标元数据暴露；关闭它不影响 bbolt 的在线 Bandit/TinyRouter 更新。该 CSV 可能包含目标/网络派生特征，导出/分享前必须考虑隐私和脱敏。

**自动长期学习 ≠ 自动重训 Model.bin**：Lite / Middle / Large 属于可替换的 LightGBM 教师模型，`uselightgbm` 控制是否用于推理。在线学生持续修正模型和传统评分，当前不会在后台改写或训练一个新的 LightGBM 权重文件。

## 这次 Bettbox 接入修正

- 对用户通过 Bettbox 自愿将 Selector / URLTest / Fallback / LoadBalance 转换成 Smart 的组，`uselightgbm` 未明确指定时默认为 true，使首包携带的 Lite 可参与评分。
- 订阅 YAML 中已有 `uselightgbm: false` 必须保留；原生 Smart 组也不强行改写；`GLOBAL` 不转换。
- `collectdata` 不强制开启；原来的代理组、订阅配置、系统代理/TUN 模式均不额外增加学习开关。
- 提醒 UI：自动学习根据实际连接反馈运行，“保存离线训练样本”只是高级选项。
- `test/smart_learning_policy_test.dart` 覆盖模型默认、明确关闭、原生组不改、GLOBAL 和重复应用幂等。
- Smart Go `component/smart/persistence_roundtrip_test.go` 将 Bandit 和 Tiny Router 权重写入 bbolt，关闭数据库、重新打开并检查相同字段；Go race CI 成功。

## 待进一步实现 / 验证

- 真实 Windows 安装/便携程序的关机→重启→切网学习行为仍需要实机检验；Go 单测不能替代文件权限、杀进程或电源突断测试。
- **普通 Bettbox 备份目前不包含 `cache.db`**。这不会妨碍同一目录的普通启动/重启，但换设备、换数据目录或恢复配置时可能不继承历史经验。未来应设计可选的事务式数据库快照/恢复；因为数据库中可能包含目标和节点信息，不应擅自加入自动云备份。
- 当前 Smart 使用由配置文件基础名 `config` 和 Smart 组名构成的持久化命名空间。多个订阅配置中名称相同的 Smart 组可能共享相同历史键；长期应引入稳定、隐私安全的每 Profile 学习域，设计无损旧数据迁移后再开启。
- 具体目标的旧统计有周期性清理和时效衰减，这是一套**有界持续学习**系统，不是无限累积、越用越大的数据库。需要以运行中的磁盘大小、累计样本、队列丢弃和真实网络恢复表现决定是否增加长期摘要存储。

## 验收原则

1. 不使用任何手动训练开关，Smart TCP/UDP 完成连接仍能产生并持久化学习记录。
2. 在相同数据目录重启后可加载先前记录；切换出口网络时旧置信度衰减，新网络可以继续学习。
3. LightGBM 模型缺失或损坏时仍可降级到传统评分和在线小学生，不造成全局网络崩溃。
4. 长时间空闲时学习工作线程保持待机；数据库不随空闲持续增长。
5. 用户明确关闭某个组的模型评分或退出 Smart 模式时，必须尊重设置；不偷偷打开离线样本采集。

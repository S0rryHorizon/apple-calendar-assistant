# Apple 日历智能助手

这个项目保留 Apple 日历和提醒事项作为界面，只增加一个本地 EventKit Bridge 和 Codex Skill。Bridge 负责可靠读写、冲突/重复检测和批次回滚；Skill 负责理解文字、课表、截图、文件与网页。

这是一个面向 macOS 的个人效率工具，不提供独立日历界面、云服务器或第三方通知服务。

普通使用者请先阅读：[用户手册](docs/USER_GUIDE.md)。

## 要求与限制

- macOS、Swift 工具链和 Apple EventKit；默认日历与提醒列表必须是 iCloud 容器。
- 原生“提前提醒”字段由 `CalendarBridgePrivate` 调用 macOS 的私有 ReminderKit 接口写入。它不是 Apple 公共 SDK，可能随 macOS 更新而变化；本项目在 macOS 26.5.2 上验证。
- 由于私有 ReminderKit 的限制，提醒事项写入依赖安装脚本编译出的本地辅助程序；如果系统不再提供相应接口，日历事件仍可使用，但提醒事项需要适配后才能继续写入。
- 该项目不适合提交 Mac App Store；使用前请检查源码、权限声明和本地隐私策略。

## 隐私

所有读写都在本机完成。操作数据库只保存撤销所需的规范化前后字段和短来源标识，不保存原始截图、课表文件或网页副本。日历、提醒事项和通知内容仍由 Apple/iCloud 按系统设置同步。

## 安装

### 源码安装

```sh
./scripts/install.sh
```

也可以从 [GitHub Releases](https://github.com/S0rryHorizon/apple-calendar-assistant/releases) 下载预编译的 Apple Silicon 实验包，按[用户手册](docs/USER_GUIDE.md)中的校验和安装步骤操作。

安装完成后，Bridge 位于 `~/Applications/CalendarBridge.app`，原生提醒事项字段辅助程序位于
`~/Applications/CalendarBridgePrivate`，Skill 位于 `~/.codex/skills/apple-calendar-assistant`。

首次初始化会显示 macOS 的日历和提醒事项权限弹窗，但不会创建任何事项：

```sh
echo '{"action":"setup"}' | ~/Applications/CalendarBridge.app/Contents/MacOS/CalendarBridge
```

Bridge 会检查当前默认日历和默认提醒列表是否属于 iCloud。可随时只读检查状态：

```sh
echo '{"action":"status"}' | ~/Applications/CalendarBridge.app/Contents/MacOS/CalendarBridge
```

之后可以在 Codex 中直接说“帮我把明天下午三点的图书馆学习加到日历”，或上传课表并要求导入。批量、冲突、重复、修改、删除和回滚会先征求确认。

## 验证

```sh
swift run CalendarBridgeSelfTest
swift run CalendarBridgeReliabilityTests
swift run CalendarBridgeServiceTests
swift run CalendarBridgeServiceTests --demo
python3 -m venv .venv
.venv/bin/python -m pip install -r Tests/requirements.txt
.venv/bin/python -m unittest Tests/parser_test.py Tests/installer_test.py
python3 -m unittest Tests/notification_smoke_test.py
```

`CalendarBridgeServiceTests --demo` 是可直接运行的受控 synthetic 演示：它打印原列表中
已完成提醒恢复与查询失败时的 `unknown`。完整测试也直接调用
`EventKitService.handle`，只使用临时 SQLite、操作 journal 和虚构的恢复后端，
不会访问真实 Calendar、Reminders、TCC 或私人辅助程序。场景覆盖查询歧义、
删除后的独立核对、原容器恢复、已完成提醒状态和写入后失败。详见
[可靠性验证与恢复边界](docs/RELIABILITY.md)。

需要验证真实 iCloud 同步和系统通知时，主动运行：

```sh
./scripts/notification-smoke-test.sh
```

它会请求权限，先预览无冲突、无重复的测试事件，再用同一批次 ID 提交；只有收到明确的 `committed` 回执才提示等待通知和输出清理命令。通知出现后运行清理命令，脚本只在收到同 ID 的 `rolled_back` 回执时报告清理成功。调用失败或结果不确定时保留批次 ID，供人工核查，不自动重试或清理。

接口细节由已安装 Skill 的 `references/interface.md` 维护。本地操作记录存放在 `~/Library/Application Support/CalendarBridge/operations.sqlite`，不会保存原始课表、截图或网页。

事件和提醒的接口回读也会返回 `location`；写入后应以 EventKit 实际读回的地点为准。

提醒事项的“提前提醒”不是 EventKit 的普通 alarm。Bridge 对单条提醒使用
`CalendarBridgePrivate` 写入 iCloud Reminders 的原生 Early Reminder 字段，因此
iPhone 会同时显示正确的截止日期和“提前提醒”；该辅助程序使用当前 macOS 的
ReminderKit 私有接口，若系统升级后失效，可能需要适配私有接口；重新编译不保证恢复。

## 开源许可

本项目采用 MIT License，详见 `LICENSE`。

## Protocol 2 可靠性边界

写入需要稳定的操作 ID 和匹配的预览；部分修改使用 `event.patch` / `reminder.patch`。
不确定结果可用 `operation.status` / `operation.reconcile` 核查，同一操作 ID 不会重新执行写入。
回滚只有在明确找到原事项或可证明其缺席时才继续；旧快照缺少原容器、容器失效、
事项身份不明或提醒完成状态未知时保留 `unknown`。这不能保证 exactly-once，
详见[可靠性验证与恢复边界](docs/RELIABILITY.md)。

使用 `scripts/install.sh` 一同安装 Bridge 与 Skill。安装器会暂存并校验文件、
替换应用和 Skill、在失败时回退，并将哈希记录在私人安装清单中。
配置保存在 Skill 目录之外；`diagnostics` 无需请求日历权限即可检查安装状态。

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
python3 -m unittest Tests/parser_test.py
```

需要验证真实 iCloud 同步和系统通知时，主动运行：

```sh
./scripts/notification-smoke-test.sh
```

它会请求权限、创建一条约一分钟后提醒的测试事件，并输出对应的清理命令。通知出现后运行清理命令即可按批次撤销，不会触碰其他事项。

接口细节由已安装 Skill 的 `references/interface.md` 维护。本地操作记录存放在 `~/Library/Application Support/CalendarBridge/operations.sqlite`，不会保存原始课表、截图或网页。

事件和提醒的接口回读也会返回 `location`；写入后应以 EventKit 实际读回的地点为准。

提醒事项的“提前提醒”不是 EventKit 的普通 alarm。Bridge 对单条提醒使用
`CalendarBridgePrivate` 写入 iCloud Reminders 的原生 Early Reminder 字段，因此
iPhone 会同时显示正确的截止日期和“提前提醒”；该辅助程序使用当前 macOS 的
ReminderKit 私有接口，若系统升级后失效，重新运行安装脚本即可重建。

## 开源许可

本项目采用 MIT License，详见 `LICENSE`。

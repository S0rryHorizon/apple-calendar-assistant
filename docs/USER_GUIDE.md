# Apple 日历智能助手用户手册

## 它是什么

本项目把 Apple 日历、提醒事项和 iCloud 作为实际界面与同步层，Bridge 在本机负责读写，Codex Skill 负责把文字、截图、课表文件和网页内容转换成日历事件或提醒事项。

它没有独立的日历网页，也不需要云服务器。固定时间的课程、约会和时间块进入“日历”；没有固定时段的任务进入“提醒事项”。

## 使用前提

- 一台 macOS 电脑。
- Apple 日历和提醒事项已登录 iCloud。
- 默认日历和默认提醒列表都使用 iCloud 容器。
- Codex Desktop 已安装并能读取个人 Skills 目录。

“提前提醒”使用 macOS 当前版本的私有 ReminderKit 接口。它在本项目验证过的 macOS 26.5.2 上可用，但 Apple 更新系统后可能需要重新编译或适配。

## 方式一：从源码安装

这是目前最可靠、也最容易排查问题的方式。它需要 Swift 工具链（通常随 Xcode Command Line Tools 提供）。

```sh
git clone https://github.com/S0rryHorizon/apple-calendar-assistant.git
cd apple-calendar-assistant
./scripts/install.sh
```

安装脚本会：

1. 构建 `CalendarBridge.app`；
2. 编译 `CalendarBridgePrivate` 原生提醒辅助程序；
3. 安装 Bridge 到 `~/Applications/CalendarBridge.app`；
4. 安装辅助程序到 `~/Applications/CalendarBridgePrivate`；
5. 安装 Codex Skill 到 `~/.codex/skills/apple-calendar-assistant`。

首次使用前运行：

```sh
echo '{"action":"setup"}' | ~/Applications/CalendarBridge.app/Contents/MacOS/CalendarBridge
```

在 macOS 弹窗中允许日历和提醒事项的完整访问权限。然后检查状态：

```sh
echo '{"action":"status"}' | ~/Applications/CalendarBridge.app/Contents/MacOS/CalendarBridge
```

输出中的 `eventSourceIsICloud` 和 `reminderSourceIsICloud` 都应为 `true`。

## 日常使用

安装 Skill 后，可以直接在 Codex 中说：

- “把明天下午三点到四点的图书馆学习加入日历。”
- “把这张课表导入日历，先预览再确认。”
- “把这个截止日期加入提醒事项，提前一周提醒。”
- “列出下个月的课程。”

没有明确日期时，助手会先追问；批量导入、冲突、重复、修改、删除和回滚会先预览并要求确认。

默认提醒是事项前一个自然日 22:00。提醒事项的单条提前提醒会写入 Apple 原生的“提前提醒”字段，因此截止日期不会被错误改成提醒日期。

## 直接调用 Bridge

Bridge 通过 JSON stdin/stdout 工作。完整接口见 [`skill/apple-calendar-assistant/references/interface.md`](../skill/apple-calendar-assistant/references/interface.md)。例如预览一个日历事件：

```sh
cat <<'JSON' | ~/Applications/CalendarBridge.app/Contents/MacOS/CalendarBridge
{
  "action": "event.create",
  "dryRun": true,
  "item": {
    "kind": "event",
    "title": "图书馆学习",
    "start": "2026-09-03T15:00:00+08:00",
    "end": "2026-09-03T16:00:00+08:00",
    "timezone": "Asia/Singapore",
    "location": "Room 201"
  }
}
JSON
```

## 通知测试与清理

如需确认 Mac 和 iPhone 的系统通知链路：

```sh
./scripts/notification-smoke-test.sh
```

脚本会创建一条可回滚的测试事件，并在输出中给出清理命令。通知测试完成后务必执行该清理命令。

## 从 GitHub Release 安装

GitHub Release 可以携带预编译的 `.zip`、`.dmg` 或其他二进制附件，使用者无需安装 Swift 即可运行。预编译包应同时包含：

- `CalendarBridge.app`；
- `CalendarBridgePrivate`；
- `apple-calendar-assistant` Skill；
- 一个只负责复制文件、设置权限并提示授权的安装脚本。

但当前项目使用私有 ReminderKit 辅助程序，而且开发环境没有 Developer ID 签名证书，因此暂不把未签名的单架构二进制冒充正式安装包。未签名下载包可能触发 Gatekeeper，并且不能给用户提供稳定的跨 macOS 版本保证。

正式发布二进制时，建议构建 Apple Silicon 与 Intel 通用版本，并使用 Developer ID 签名、Hardened Runtime 和 Apple notarization。否则应把源码安装作为默认路径，并在 Release 说明中明确“实验性、未签名、仅限特定 macOS 版本”。

## 权限、数据和故障排查

- Bridge 只使用本机 EventKit；原始截图、课表文件和网页不会被长期保存。
- 撤销数据库位于 `~/Library/Application Support/CalendarBridge/operations.sqlite`，只保存批次和规范化前后字段。
- 如果状态显示不是 iCloud，先在系统设置中切换默认日历或提醒列表，再重试。
- 如果提醒事项写入失败，先重新运行 `./scripts/install.sh`；若 macOS 更新后仍失败，通常是私有 ReminderKit 接口发生变化。
- 如果 iPhone 没有立即显示，打开对应 App 并下拉刷新，等待 iCloud 同步。

## 卸载

在 Finder 中删除以下项目即可移除本地安装：

- `~/Applications/CalendarBridge.app`
- `~/Applications/CalendarBridgePrivate`
- `~/.codex/skills/apple-calendar-assistant`

如需同时删除本地撤销记录，再删除 `~/Library/Application Support/CalendarBridge/operations.sqlite`；这会使已有批次无法回滚。

# QQRealPush v1.1.0 — QQ 前后台实时推送横幅（诊断增强版）

不依赖苹果远程推送（APNs）的 QQ 消息横幅插件。**本地通知取代苹果通知**，前台后台均弹横幅。

v1.1.0 新增**诊断模式**，用于定位 QQ 内部消息接收路径。

## v1.1.0 诊断功能

安装后 QQ 启动时会自动执行以下诊断，结果写入日志文件：

**日志文件**：`/var/mobile/Library/Preferences/com.qq.realpush.log`

### 诊断内容

| 诊断项 | 说明 |
|--------|------|
| 加载确认 | 确认插件已加载 |
| 通知权限 | QQ 是否已授予通知权限 |
| 测试通知 | 启动 3 秒后发一条测试横幅（验证通知系统是否正常） |
| NSNotification 日志 | 记录 QQ 发出的所有通知名和对象类名 |
| Badge 变化 | 记录 QQ 角标数字变化（消息到达信号） |
| 声音/振动 | 记录 AudioServicesPlaySystemSound 调用（消息提示音） |
| 远程推送 | 拦截 APNs 推送 payload |
| 类发现 | 记录 QQ 中含 Message/Chat/Session 的类名 |

### 使用方法

1. 安装 deb，确保 **设置→通知→QQ→允许通知** 打开
2. 打开 QQ，等 3 秒看是否弹出**测试通知**
   - ✅ 弹出 = 通知系统正常
   - ❌ 未弹出 = 权限问题或插件未加载
3. 让对方发一条 QQ 消息给你
4. 查看日志文件（Filza 或 SSH）：
   ```bash
   cat /var/mobile/Library/Preferences/com.qq.realpush.log
   ```
5. 把日志内容发给我分析

### 如何解读日志

- **`loaded`** → 插件已加载
- **`notification auth status: 1`** → 通知权限未授予（需要 1，不是 0/2/3）
- **`test notification result: success`** → 通知系统正常
- **`NOTIF: name=...`** → QQ 发出的通知名列表
- **`MSG MATCH: name=...`** → 命中消息检测的通知
- **`badge number: 0 -> 1`** → 角标变化（消息到达）
- **`AudioServicesPlaySystemSound: XXX`** → 声音播放（消息提示音）
- **`didReceiveRemoteNotification:`** → APNs 推送到达
- **`swizzled willPresentNotification`** → 前台横幅强制已激活
- **`CLASS: XXX`** → QQ 消息相关类名

## 工作原理

### Part 1：前台横幅强制
- iOS 默认前台不弹横幅（delegate 返回 0）
- Hook `UNUserNotificationCenter.setDelegate:`，swizzle 代理类的 `willPresentNotification:`
- 强制返回 `Banner | List | Sound`，前台也弹横幅
- 延迟 2 秒检查现有 delegate 并 swizzle（处理 hook 加载前已设置的 delegate）

### Part 2：本地通知生成（多路检测）
- **NSNotificationCenter**：hook `postNotification:`，过滤含 msg/message/chat/recv 关键词
- **Badge 变化**：hook `setApplicationIconBadgeNumber:`，角标增加 = 可能收到新消息
- **声音/振动**：hook `AudioServicesPlaySystemSound`，检测消息提示音
- **APNs 拦截**：swizzle AppDelegate 的 `didReceiveRemoteNotification:fetchCompletionHandler:`，提取 payload 转本地通知
- 命中后投递 `trigger:nil` 本地通知（前后台均立即触发）

### Part 3：清理
- 打开 QQ 时自动清理 `qrp-` 前缀的已弹出通知

## 设置

文件：`/var/mobile/Library/Preferences/com.qq.realpush.plist`

| Key | 默认 | 说明 |
|-----|------|------|
| Enabled | YES | 总开关 |
| FrontBanner | YES | 前台也弹横幅 |
| ShowContent | YES | 显示消息内容 |
| OnlyOthers | YES | 只推送别人的消息 |
| Sound | YES | 播放提示音 |
| ClearOnOpen | YES | 打开 QQ 时清理已弹出通知 |
| Debug | YES | 诊断日志（写入 log 文件） |
| TestNotify | YES | 启动后发测试通知 |

修改后 `killall -9 QQ` 重启生效。

## 安装

```bash
dpkg -i com.qq.realpush_1.1.0_iphoneos-arm64.deb
```

或用 Sileo/Filza 安装。

## 必要条件

1. **系统通知权限**：设置 → 通知 → QQ → 打开"允许通知"
2. **QQ 进程存活**：插件跑在 QQ 内部，QQ 被杀掉后不推送
3. **iOS 15+**

## 已知限制

- 通用回退方案可能漏掉不走 NSNotification 的消息，或对无关通知产生噪音
- 精确方案（hook QQ NT 消息类的确切选择器）需要 Frida 侦察后填入
- Debug 模式会写日志文件，确认问题后可设 `Debug=NO` 关闭

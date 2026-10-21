# QQRealPush — QQ 前后台实时推送横幅

不依赖苹果远程推送（APNs）的 QQ 消息横幅插件。合并两大功能：

1. **前台横幅强制**：swizzle `UNUserNotificationCenter` 代理的 `willPresentNotification:`，强制返回 `Banner | List | Sound`，使前台也显示横幅（iOS 默认前台不弹横幅）
2. **本地通知生成**：hook QQ 内部 `NSNotificationCenter` 消息通知，提取发送者/内容，投递 `trigger:nil` 本地通知（前后台均立即触发）

**前台、后台都能弹横幅。** 适合 QQ 远程推送收不到的场景（服务端没发 / 代理阻断 APNs / apsd 异常），只要 QQ 在后台存活即可推送。

## 必要条件

1. **系统通知权限**：设置 → 通知 → QQ → 打开"允许通知"（本地通知与远程推送共用同一权限）
2. **QQ 进程存活**：插件跑在 QQ 内部，QQ 在后台活着就能推；被手动杀掉后不推送
3. **iOS 15+**

## 安装

```bash
dpkg -i com.qq.realpush_1.0.0_iphoneos-arm64.deb
# 会自动 killall QQ 重启生效
```

或用 Sileo/Filza 安装 deb。

## 设置

设置文件 `/var/mobile/Library/Preferences/com.qq.realpush.plist`：

| Key | 默认 | 说明 |
|---|---|---|
| Enabled | YES | 总开关 |
| FrontBanner | YES | 前台也弹横幅（关闭则只在后台弹） |
| ShowContent | YES | 显示消息内容（NO 则只显示"你收到一条新消息"） |
| OnlyOthers | YES | 只推送别人的消息（不推送自己发的） |
| Sound | YES | 播放提示音 |
| ClearOnOpen | YES | 打开 QQ 时清理已弹出的通知 |

修改后 `killall -9 QQ` 重启 QQ 生效。

## 工作原理

### 前台横幅强制（Part 1）
- Hook `UNUserNotificationCenter.setDelegate:`
- QQ 设置通知代理时，swizzle 代理类的 `willPresentNotification:withCompletionHandler:`
- 在 swizzled 方法中，包裹 completion handler，无论原实现返回什么都覆盖为 `Banner | List | Sound`
- 对远程推送和本地通知都生效

### 本地通知生成（Part 2）
- Hook `NSNotificationCenter.postNotification:`
- 过滤通知名/对象类名含 msg/message/chat/recv 等关键词的通知
- 从通知 object 和 userInfo 提取 发送者/内容/消息ID
- 构造 `UNMutableNotificationContent`，以 `trigger:nil`（立即触发）投递
- `trigger:nil` 的本地通知无论前后台都会展示横幅（前台需 Part 1 配合）
- 同一消息 ID 去重，避免重复弹

### 清理
- 打开 QQ（`UIApplicationDidBecomeActiveNotification`）时自动清理 `qrp-` 前缀的已弹出通知

## 编译

需要 macOS + Theos（GitHub Actions CI）：

```bash
# 仓库自带 .github/workflows/build.yml
# push 到 GitHub 即触发编译
git push origin main
# Actions 完成后下载 artifact: com.qq.realpush_1.0.0_iphoneos-arm64.deb
```

> 必须用 macOS Apple clang 编译（生成 arm64e PAC stubs）。Linux clang 19 无法生成 PAC stubs，arm64e 进程加载后 objc 调用即 crash。

## 限制与待办

- Part 2 的消息检测是通用回退方案（hook NSNotificationCenter），可能漏掉不走 NSNotification 的消息、或对无关通知产生噪音。若误报多，可关 `FrontBanner` 只在后台弹
- 精确方案（hook QQ NT 消息类的确切选择器）需要 Frida 侦察后填入

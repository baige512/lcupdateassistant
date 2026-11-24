# LCUpdateAssistant · LiveContainer 软件源辅助插件（v1.9）

一个 Theos tweak，装进 LiveContainer 后多出三个能力：

1. **「源」页顶部常驻蓝色按钮「激活软件源」**，点开设置菜单（只在源页显示，其它页面/客制 App 里自动隐藏）。
2. **卡密解锁**：摇一摇或点按钮 → 卡密或 UDID 二选一 → 直接调后台 `api.php` 激活/验证。
3. **解锁后自动导入专属源**：成功那一刻就把「带 UDID 的源地址」写进 LiveContainer 的软件源列表并立即刷新，不用再手动复制粘贴。

> 另外保留回前台静默查源、本机版本落后时提示的能力；原来那个点了没反应的「立即检查更新」入口已删除。

## 没有 Mac？用 GitHub Actions 编译（推荐）

工程里已经放好 `.github/workflows/build.yml`，GitHub 免费提供 macOS 云主机，不用装 Theos、不用命令行：

1. 注册/登录 GitHub，新建一个**公开仓库**（公开仓库的 Actions 免费额度够用）。
2. 把工程**整个目录**传上去（含隐藏的 `.github` 文件夹）。网页拖拽上传时有时会漏掉隐藏目录，传完在仓库页面确认能看到 `.github/workflows/build.yml`；用 git 推最省事。
3. 打开仓库 **Actions** 标签 → 左侧选 **Build LCUpdateAssistant** → 点 **Run workflow**（或 push 一次代码自动触发）。
4. 跑完后点进这次运行，底部 **Artifacts** 里有 `LCUpdateAssistant-dylib`，下载解压得到 `.dylib`。

## 有 Mac 的话本地编译

```bash
git clone --recurse-submodules https://github.com/theos/theos.git $THEOS
cd LCUpdateAssistant
make
# 产物：.theos/obj/debug/LCUpdateAssistant.dylib
```

## 装进 LiveContainer

1. 把 dylib 传到手机。
2. LiveContainer → 模块 → 全局文件夹 → 导入该 dylib，签名。
3. 打开 LiveContainer，切到「源」页，顶部中间出现蓝色「激活软件源」按钮。
4. 点按钮 →「卡密解锁」→ 填卡密或 UDID → 解锁成功即自动导入专属源。

按钮被隐藏了：切到「模块」页**双击屏幕**即可恢复。

## 自动导入是怎么做的

不靠模拟点击，走的是 LiveContainer 自己那套数据：

| 步骤 | 做的事 |
|---|---|
| 1 | 写 `NSUserDefaults` 的 `LCAltStoreSourceURLs`（LiveContainer 源列表就是存这个字符串数组），同域名的旧地址（无 udid / 旧 udid）顺手替换 |
| 2 | 把拉到的源 JSON 写进 `Caches/AltStoreSourceCache/<sha256(源地址)>.json`，进「源」页立刻有内容 |
| 3 | 打开官方深链 `livecontainer://source?url=<源地址>`，等价于点右上角「+」粘贴地址，列表当场刷新 |

所以就算深链在个别版本上没走通，源也已经写进列表了，重启一次 LiveContainer 就能看到。

## 关于解锁，必须知道的限制

| 目标 | 能否 |
|---|---|
| 在 App 内输卡密、调 `api.php` 激活 | ✅ 能，走的就是你后台 `CardKey::activate()` 同一套逻辑 |
| 已激活用户只填卡密解锁 | ✅ query 查绑定 UDID → validate 确认未过期 |
| 已激活用户只填 UDID 解锁 | ✅ validate 确认已激活未过期 |
| 自动拿到真机 UDID | ❌ **不可能**。iOS 普通 App 拿不到真 UDID，`identifierForVendor` 跟后台设备表对不上。UDID 仍需用户用 Safari 装描述文件获取后手输/粘贴 |
| 解锁后付费 App 出现在源里 | ✅ 能，`altstore.php/apps.json?udid=xxx` 返回付费应用，插件负责把带 udid 的地址自动加进源 |

## 配置（两种方式）

**方式一：改源码顶部常量再编译**（`Tweak.mm` 顶部）
```
kDefaultSourceURL  源地址
kDefaultAPIURL     激活接口 api.php
kDefaultAPIKey     后台 API 密钥（后台没配就留空）
kCheckInterval     检查间隔秒
kEnableShakeUnlock 是否开启摇一摇解锁
kEnableFloatButton 是否显示顶部按钮
```

**方式二：plist 覆盖**（不用重编译）—— 把 `com.internal.lcupdateassistant.plist` 传到手机这两个路径之一：
```
/var/mobile/Library/Preferences/com.internal.lcupdateassistant.plist
<App 容器>/Documents/com.internal.lcupdateassistant.plist
```
可写 `sourceURL` / `apiURL` / `apiKey` / `interval`。

## 版本记录

- **v1.9**：按钮改蓝色（#0A7AFA）；删除「诊断软件源」和没起作用的「立即检查更新」；解锁/激活成功后**自动导入专属源到软件源**（写 `LCAltStoreSourceURLs` + 预置缓存 + `livecontainer://source` 深链），菜单新增「导入专属源到软件源」手动兜底
- **v1.8**：去掉首次加载弹窗；收紧判定（用 lcMainBundle + 路径双重判断，客制 App 里彻底不显示）；隐藏按钮后可在「模块」页双击屏幕恢复显示
- **v1.7**：新增「诊断软件源」；按钮只在 LiveContainer「源」tab 显示，其它页面和客制 App 里自动隐藏（每 0.5s 跟随 tab）
- **v1.6**：按钮固定到屏幕顶部居中（避开安全区），改成胶囊样式并把名字改为「激活软件源」；去掉拖动
- **v1.5**：解锁支持「二选一」——已激活未过期用户只填卡密（query 查绑定 UDID 再 validate）或只填 UDID（validate）即可；两个都填仍是新卡激活
- **v1.4**：新增常驻悬浮设置按钮（点击弹设置菜单），保留摇一摇
- **v1.2**：新增摇一摇解锁（卡密 + UDID → api.php 激活）、激活成功给专属源地址、UDID 记忆预填
- **v1.1**：修复 observer 未强引用导致通知收不到（v1.0 装上等于没装）；key 按 App 分开；去掉不可靠的 `canOpenURL`；首次运行提示；弹窗重试
- **v1.0**：更新检测初版

## 文件清单

- `Makefile` / `control` —— Theos 构建
- `Tweak.mm` —— 插件逻辑（纯 ObjC++，不依赖 CydiaSubstrate）
- `com.internal.lcupdateassistant.plist` —— 配置模板
- `.github/workflows/build.yml` —— GitHub Actions 自动编译
- `README.md` —— 本文档

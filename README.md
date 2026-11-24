# LCUpdateAssistant · LiveContainer 软件源辅助插件（v1.2 解锁版）

一个 Theos tweak，装进 LiveContainer 后给客制 App 加两个能力：

1. **更新检测**：App 回前台静默查源，发现新版本弹窗，给出「复制/打开源地址」。
2. **卡密解锁**：摇一摇手机 → 弹窗输入卡密 + UDID → 直接调你后台 `api.php?action=activate` 激活 → 成功后给出带 udid 的专属源地址。

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
3. 打开任意 App，1.5 秒内弹「LCUpdateAssistant 已加载」= 插件活了。
4. 想解锁：在 App 里**摇一摇** → 填卡密 + UDID → 点激活。

## 关于解锁，必须知道的限制

| 目标 | 能否 |
|---|---|
| 在 App 内输卡密、调 `api.php` 激活 | ✅ 能，走的就是你后台 `CardKey::activate()` 同一套逻辑 |
| 自动拿到真机 UDID | ❌ **不可能**。iOS 普通 App 拿不到真 UDID，`identifierForVendor` 跟后台设备表对不上。UDID 仍需用户用 Safari 装描述文件获取后手输/粘贴 |
| 激活后付费 App 出现在源里 | ✅ 能，靠 `altstore.php/apps.json?udid=xxx`，由源本身完成，插件只负责把带 udid 的地址给出来 |

激活成功后插件会记住 UDID（下次预填），并生成 `源地址?udid=xxx`，用户复制去 LiveContainer 加源即可。

## 配置（两种方式）

**方式一：改源码顶部常量再编译**（`Tweak.xm` 第 26–31 行）
```
kDefaultSourceURL  源地址
kDefaultAPIURL     激活接口 api.php
kDefaultAPIKey     后台 API 密钥（后台没配就留空）
kCheckInterval     检查间隔秒
kEnableShakeUnlock 是否开启摇一摇解锁
```

**方式二：plist 覆盖**（不用重编译）—— 把 `com.internal.lcupdateassistant.plist` 传到手机这两个路径之一：
```
/var/mobile/Library/Preferences/com.internal.lcupdateassistant.plist
<App 容器>/Documents/com.internal.lcupdateassistant.plist
```
可写 `sourceURL` / `apiURL` / `apiKey` / `interval`。

## 版本记录

- **v1.2**：新增摇一摇解锁（卡密 + UDID → api.php 激活）、激活成功给专属源地址、UDID 记忆预填
- **v1.1**：修复 observer 未强引用导致通知收不到（v1.0 装上等于没装）；key 按 App 分开；去掉不可靠的 `canOpenURL`；首次运行提示；弹窗重试
- **v1.0**：更新检测初版

## 文件清单

- `Makefile` / `control` —— Theos 构建
- `Tweak.xm` —— 插件逻辑（v1.2）
- `com.internal.lcupdateassistant.plist` —— 配置模板
- `.github/workflows/build.yml` —— GitHub Actions 自动编译
- `README.md` —— 本文档

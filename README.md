# 白云钥匙 · iOS 原生版

蓝牙门禁离线开锁，SwiftUI，无第三方依赖。

配套网页版：<https://baiyunkeys-web.pages.dev/>，一套格式互通，导入导出直接搬。

## 安装

下载最新版：[Releases · 最新](https://github.com/YiwanGo/BaiyunKeys-iOS/releases/latest)。

产物是**免签名** IPA，需要自签后安装。常见方式：

- **TrollStore**：直接装，长期有效。
- **AltStore / SideStore**：Apple ID 签名，7 天有效期，到期用电脑或 AltStore 重签。
- **Sideloadly / Esign**：p12 证书签名，按证书有效期使用。
- **Xcode**：连上真机直接 Run（走 `跑起来` 那节）。

## 跑起来

Xcode 16、iOS 17+、真机（模拟器没蓝牙）。

打开 `BaiyunKeys.xcodeproj`，改 target 的 Bundle ID 和签名 Team，⌘R。首次开锁会弹一次系统蓝牙授权。免费开发者账号签的 App 7 天有效期，到期重跑一次即可。

## 用法

配置 → 新增门禁，填 MAC / Key / 蓝牙名 / 一个自己认得的门禁名。回首页点中间那个大圆按钮。

蓝牙名 iOS 必填 —— CoreBluetooth 不给 App 读外设 MAC，扫描只能靠名字。

## 快捷指令 / 操作按钮 / Siri

App 注册了两个 App Intent，都能绑到快捷指令、操作按钮、轻点背面、Siri：

- **立即开锁**：打开 App 后由 RootView 接管开锁流程。
- **后台开锁**：不打开 App，直接跑蓝牙握手再回一句提示。

## 已知限制

- 前台开锁最稳；后台入口受 iOS 后台运行时长限制，链路慢时可能中途失败。
- 操作按钮 / 轻点背面等硬件入口只有 iPhone 15 Pro 及以后机型有；快捷指令和 Siri 全机型可用。
- CoreBluetooth 不向 App 暴露外设 MAC，扫描只能靠蓝牙名。

## 免责声明

只是把你本人已获授权的门禁凭据在本地离线复用，不含破解 / 绕过 / 提权，也不上传任何东西到服务器。请仅在有权进入的门禁上使用，违规后果自负。部分特殊功能默认不显示，如何开启可能需要您自行阅读源码。

# 构建、安装与发布说明

> 这份文件是「拿到仓库就能装起来」的那一页。测试情况与已知限制见
> `docs/TEST_REPORT.md`，人工核对清单见 `docs/MANUAL_CHECKS.md`。

## 1. 构建

```powershell
Set-Location app
flutter pub get
flutter build apk --debug      # 调试包，含设计走查入口
flutter build apk --release    # 发布包，不含设计走查入口
```

产物：

* 调试包 `app/build/app/outputs/flutter-apk/app-debug.apk`
* 发布包 `app/build/app/outputs/flutter-apk/app-release.apk`

## 2. 安装

```powershell
adb install -r app/build/app/outputs/flutter-apk/app-debug.apk
```

⚠️ `flutter install` 默认装 **release** 包，而且会先卸载旧版（数据一起没）。
要装调试包请直接 `adb install -r` 加上面的路径。

## 3. 本机环境上要注意的两件事

* **Impeller 会让这台机器的屏幕变白**（设备端图形问题，不是应用缺陷）。
  用 `flutter run --no-enable-impeller`，或者直接装 APK 包。
* 改过 Kotlin 之后**必须真编译一次**（`flutter build apk --debug`）：
  `flutter analyze` 只看 Dart，Kotlin 的可空/语法错误只有编译才暴露 ——
  这个坑真的踩过。

## 4. 签名与发布

正式签名已经接好，凭据读的是 `app/android/key.properties`（**这个文件不进仓库**，
`app/android/.gitignore` 里已忽略）。文件长这样：

```properties
storePassword=…
keyPassword=…
keyAlias=…
storeFile=D:\\dev\\younum\\keystore\\younum_keystore.jks
```

* `storeFile` 指向仓库**外面**的 keystore（现在是 `D:\dev\younum\keystore\`，
  根 `.gitignore` 里也忽略了 `/keystore`）。
* **没有 key.properties 时构建不会失败**：自动回退到调试签名，这样别人克隆下来
  也能跑 `flutter run --release`。所以「拿到了一份签名包」这件事本身要验：
  ```powershell
  apksigner verify --print-certs --verbose build\app\outputs\flutter-apk\app-release.apk
  ```
  正式包的证书 DN 不是 `CN=Android Debug,O=Android,C=US`（调试密钥的 DN 是它）。
* ⚠️ **换了签名就等于换了一个应用**：调试签名的包和正式签名的包不能互相覆盖，
  要装正式包必须先卸载调试包 —— **数据会一起没**。所以从这一版起，
  日常试用也请统一用正式签名包：
  ```powershell
  flutter build apk --release
  adb uninstall com.younum.app     # 只在从调试签名切到正式签名时做一次
  adb install build\app\outputs\flutter-apk\app-release.apk
  ```
* ⚠️ **keystore 与两个密码必须另存一份**（U 盘、密码管理器）。丢了以后这个应用
  再也发不出能覆盖安装的更新，用户只能卸载重装。
* 密码不要贴进聊天、工单、提交信息；`key.properties` 也永远不要提交。
* 版本号在 `app/pubspec.yaml` 的 `version:`（现在 `1.0.0+1`）。**在线升级只看
  `+` 后面的 build number（versionCode）**，所以每次发布都要让它 +1。
* 还没做的：确认 `com.younum.app` 未被占用（上架前要查）。

## 5. 发布前检查清单

* [ ] 权限只有两项，且都说得清用途：
      `POST_NOTIFICATIONS`（每月提醒）、
      `WRITE_EXTERNAL_STORAGE`（**仅 Android 9 及以下**存相册，已用
      `maxSdkVersion="28"` 限住）。**没有网络权限**，与「仅本地」的承诺一致。
* [ ] `allowBackup="false"`、`dataExtractionRules` 都在（避免账单被系统云备份）。
* [ ] 设计走查路由 `AppRoutes.designReview` 只在调试构建注册（`kDebugMode`）。
* [ ] `flutter analyze` 零告警；`flutter test` 全绿；真机数据库测试全绿。
* [ ] 人工核对清单里标为未验证的项，在发布说明里如实写明。

## 6. 已知限制

见 `docs/TEST_REPORT.md` 的「未验证 / 已知限制」一节，以及 `README.md`
的「已知限制」。摘要：提醒的真实送达依赖系统调度（本机验证过，但延迟由系统
决定）；桌面与 Web 不支持选择文件、保存、提醒；应用私有存储**不等于**
数据库已加密。


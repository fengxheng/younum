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

* **改过 Kotlin / Manifest / Gradle 或依赖之后，一定要 `flutter build apk --release`
  并装到真机上点开看一眼。** release 会跑 R8 而 debug 不会，所以「反射实例化被
  当成死代码裁掉」这类问题**只在正式包里出现**，`flutter analyze`（只管 Dart）
  和 debug 构建都看不见。上一轮的真实现象是：release 包装好后**点开图标什么都没发生**
  —— 没有白屏、没有闪退提示、logcat 里也一条 `flutter` 日志都没有（崩在引擎起来之前），
  真凶是 `AndroidRuntime: NoSuchMethodException: androidx.work.impl.WorkDatabase_Impl.<init>`。
  保留规则在 `app/android/app/proguard-rules.pro`，`build.gradle.kts` 的 release
  里显式开了 R8 并挂上了它。细节见 `DECISIONS.md` 第 67 节。
* **改了 Kotlin 之后**：`flutter analyze` 只看 Dart，Kotlin 的可空/语法错误只有编译才暴露
  —— 这个坑真的踩过，所以至少要用 `flutter build apk --debug` 编一次。

> 一个**已经实测推翻**的旧说法：本机 Impeller（Vulkan）会让屏幕变白。
> 同一台机器上同一个 APK，用普通 `am start` 启动（Impeller 开着）画面完全正常。
> 所以不要再加 `io.flutter.embedding.android.EnableImpeller=false`。
> 真遇到白屏，先 `pidof` 看进程在不在：进程不在就是原生层崩了，去查 `AndroidRuntime`。

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
* 版本号在 `app/pubspec.yaml` 的 `version:`（现在 `1.2.1+4`）。**在线升级只看
  `+` 后面的 build number（versionCode）**，所以每次发布都要让它 +1。
* 还没做的：确认 `com.younum.app` 未被占用（上架前要查）。

## 5. 怎么发一个「应用内能升级到」的版本

应用内的「检查更新」读的是 GitHub 的 **Releases**（不是 tag）：

```
GET https://api.github.com/repos/fengxheng/younum/releases/latest
```

能用的 release 必须同时满足三条：

1. 是**已发布**的 Release（在 GitHub 网页上「Draft a new release」之后还要点
   「Publish release」）：**草稿**对匿名请求完全不可见，光 push 一个 tag 也不算；
2. tag 里带 **build number**，形如 `v1.2.1+4` —— 比较新旧只看它；
3. **上传了 `.apk` 资源**（不能只有源码 zip），而且必须是**正式签名**的包：
   升级是「覆盖安装」，签名不一致会被系统直接拒绝。

关于**预发布**：`releases/latest` 按定义**不返回预发布**，所以在「只发过预发布」
的阶段应用会读不到。应用的顺序是「先问 latest，404 才退回 `releases` 列表」——
也就是说：只有预发布时升级照旧能用（按 build number 取最大的那条），
一旦发了正式发布，预发布就不会再打扰用户。

发布步骤：

```powershell
Set-Location app
# 1. 改版本号：versionName 给人看，+ 后面的 build number 必须比上一版大
#    （已发布过 1.1.0+2 与 1.2.0+3，仓库里现在是 1.2.1+4）
#    下一个版本至少是 1.2.2+5
flutter build apk --release
# 2. 在 GitHub 上 New release：Tag 填 v1.2.1+4，把下面这个文件拖进去，发布
#    app/build/app/outputs/flutter-apk/app-release.apk
```

注意：

* **限流**：未登录的 GitHub API 每小时 60 次，个人使用足够；但被限流时应用会显示
  「版本信息读不到（HTTP 403）」，这是正常提示，不是缺陷。
* **网络**：这台机器在国内，GitHub 可能连不上。应用的检查是「失败就静静过去」，
  手动检查才会显示原因 —— 不会影响日常使用。
* 每次发布都要让 `+` 后面的数字 **+1**，否则应用不会认为有新版。
## 6. 发布前检查清单

* [ ] 权限共四项，且都说得清用途：
      `POST_NOTIFICATIONS`（每月提醒）、
      `WRITE_EXTERNAL_STORAGE`（**仅 Android 9 及以下**存相册，已用
      `maxSdkVersion="28"` 限住）、
      `INTERNET`（**只用于在线升级**：读一个公开的版本号，
      以及经用户同意后下载安装包 —— 账单数据不参与）、
      `REQUEST_INSTALL_PACKAGES`（把下载好的安装包交给系统安装器）。
      发布说明里**不要**再写「没有网络权限」（2026-09-25 之前是这么写的），
      要写成「联网只用于检查更新」。
* [ ] `allowBackup="false"`、`dataExtractionRules` 都在（避免账单被系统云备份）。
* [ ] 设计走查路由 `AppRoutes.designReview` 只在调试构建注册（`kDebugMode`）。
* [ ] `flutter analyze` 零告警；`flutter test` 全绿；真机数据库测试全绿。
* [ ] **正式包真的能在真机上打开**：`flutter build apk --release` 后 `adb install -r`，
      然后**点开图标看一眼**（只看安装输出里的 `Success` 不够 —— R8 的坑就是
      装得上、打不开）。同时确认 `android/app/proguard-rules.pro` 里的两条保留规则
      还在（Room 的数据库实现、WorkManager 的 Worker）：后者被裁掉不会当场崩，
      但**每月提醒会静默失灵**，更难发现。
* [ ] 人工核对清单里标为未验证的项，在发布说明里如实写明。
* [ ] **数据库确实是加密的**：装好之后按 `MANUAL_CHECKS.md` 第十六节看一眼
      文件头（不该是 `SQLite format 3`），并确认「隐私与数据」页显示已加密。
* [ ] 从上一版**覆盖安装**一遍：老库能自动搬成加密库，账目一条不少。

## 7. 已知限制

见 `docs/TEST_REPORT.md` 的「未验证 / 已知限制」一节，以及 `README.md`
的「已知限制」。摘要：提醒的真实送达依赖系统调度（本机验证过，但延迟由系统
决定）；桌面与 Web 不支持选择文件、保存、提醒；联网只用于检查更新。

**数据库是加密的，钥匙丢了数据就永久读不出。** 口令随机生成、由 Android
Keystore 里一把不可导出的密钥包住（见 `DECISIONS.md` 第 65 节）。卸载应用、
清除应用数据、换手机都会让 Keystore 里那把密钥消失 —— 旧的加密库再也打不开。
这是加密的必然代价，不是缺陷：**卸载或换机前请先在应用里导出需要保留的内容**
（导出的是 CSV，是数据导出，不是可还原的备份）。






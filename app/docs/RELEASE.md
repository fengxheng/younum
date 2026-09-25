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

* 当前 `release` 构建**沿用调试签名**（见 `android/app/build.gradle.kts` 的
  TODO），因此可以本地安装试用，但**不能直接上架**。上架前必须：
  1. 生成正式 keystore，把 `signingConfigs` 换成它；
  2. 确认应用 ID `com.younum.app` 未被占用（同文件里也有 TODO）。
* 版本号在 `app/pubspec.yaml` 的 `version:`，构建时会带进 APK。

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

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    // TODO(发布前): 确认 com.younum.app 未被占用后再上架，此处沿用实现指南 2.2 的暂定包名。
    namespace = "com.younum.app"
    compileSdk = flutter.compileSdkVersion

    // 显式指向本机**已安装**的 NDK，避免构建时触发联网安装。
    //
    // 背景：Flutter 3.47 的 Gradle 插件会把 ndkVersion 默认设成 28.2.13676358，
    // 本机装的是 30.0.16248370，于是 AGP 试图用 sdkmanager 下载缺失版本 ——
    // 而本机 sdkmanager.bat 会以 NTSTATUS 0xC0000409 崩溃，导致构建失败。
    //
    // 本工程与全部依赖都没有原生代码，NDK 只是被解析、不参与编译。
    // 将来若引入需要 NDK 的插件，请安装与插件要求一致的版本后再改这里，
    // 并注意 sdkmanager 目前不可用（见 README「已知限制」）。
    ndkVersion = "30.0.16248370"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.younum.app"
        // 实现指南 2.1: 产品取舍为 minSdk 26。
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // 每月整理提醒的调度（指南 8.2）。
    //
    // 选 WorkManager 而不是精确闹钟：这是「提醒你整理账单」，不是日历事件，
    // 系统省电造成的合理延迟可以接受 —— 换来的是**不必申请精确闹钟权限**。
    // 通知文案写「约」，与这个取舍一致。
    implementation("androidx.work:work-runtime-ktx:2.10.0")
}

flutter {
    source = "../.."
}

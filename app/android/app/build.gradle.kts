import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 发布签名。
//
// 凭据只存在 `android/key.properties`（已在 `.gitignore` 里），仓库里不出现任何密码、
// 也不出现 keystore 文件本身。文件缺失时**不报错**，而是回退到调试签名：
// 这样别人克隆下来、没拿到密钥也能把调试包和 `flutter run --release` 跑起来，
// 而正式发布时只需要自己补一份 key.properties。
//
// ⚠️ 在线升级（应用内检查新版本）依赖这里：用调试签名装的包无法被正式签名的
// 新版本覆盖安装，所以发布包必须是这一套签名。
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseSigning = keystorePropertiesFile.exists()
if (hasReleaseSigning) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
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

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // 有密钥就用正式签名；没有就暂时用调试签名，保证 `flutter run --release`
            // 在没拿到密钥的机器上也能跑。
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }

            // release 的 R8 压缩与保留规则。
            //
            // ⚠️ 规则不能少：Room 的数据库实现、WorkManager 的 Worker 都是**反射**
            // 实例化的，R8 看不到调用点会把它们裁掉，结果是「启动即退出」
            // （细节与真机崩溃原文见 proguard-rules.pro）。
            // debug 不跑 R8，所以这个坑只在正式包里出现 ——
            // 改了原生代码或依赖后，务必用 `flutter build apk --release` 真实启动一次，
            // 别只跑 debug。
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
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

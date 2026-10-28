import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release 签名（M4）：凭据优先级 环境变量 > android/key.properties（均不入库）。
// 两者都缺失时 release 回退 debug 签名，仅供本机 `flutter run --release` 冒烟；
// 正式分发产物必须带正式签名（见 docs/09-发布与分发.md）。
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) FileInputStream(f).use { load(it) }
}
fun signingProp(name: String, env: String): String? =
    System.getenv(env) ?: keystoreProperties.getProperty(name)

android {
    namespace = "com.syncreader.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.syncreader.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            // storeFile 路径以 android/（gradle rootProject）为基准解析；
            // 不能用本模块 file()——其基准是 android/app/，路径会错配回退 debug。
            val storeFileProp =
                signingProp("storeFile", "SYNCREADER_KEYSTORE_FILE")?.let { rootProject.file(it) }
            val storePasswordProp = signingProp("storePassword", "SYNCREADER_KEYSTORE_PASSWORD")
            val keyAliasProp = signingProp("keyAlias", "SYNCREADER_KEY_ALIAS")
            val keyPasswordProp = signingProp("keyPassword", "SYNCREADER_KEY_PASSWORD")
            if (storeFileProp != null && storeFileProp.exists() &&
                storePasswordProp != null && keyAliasProp != null && keyPasswordProp != null
            ) {
                storeFile = storeFileProp
                storePassword = storePasswordProp
                this.keyAlias = keyAliasProp
                this.keyPassword = keyPasswordProp
            }
        }
    }

    buildTypes {
        release {
            // 正式签名材料齐备时用 release 签名，否则回退 debug（本机冒烟用）。
            signingConfig = if (signingConfigs.getByName("release").storeFile != null) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

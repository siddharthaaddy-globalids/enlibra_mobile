import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Written by the release CI job from repository secrets, or created locally
// by a developer holding the keystore. Absent on CI debug builds and on a
// fresh clone, in which case we fall back to debug signing below.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

// ABIs to build llama.cpp for. Prefers Flutter's own -Ptarget-platform so a
// single `flutter build --target-platform` flag governs both Flutter's
// libraries and ours; see packages/llama_bridge/android/build.gradle.
val enlibraAbis: List<String> = run {
    val map = mapOf("android-arm64" to "arm64-v8a", "android-x64" to "x86_64")
    val targets = project.findProperty("target-platform") as String?
    val fromFlutter = targets?.split(",")?.mapNotNull { map[it.trim()] } ?: emptyList()
    if (fromFlutter.isNotEmpty()) fromFlutter
    else (project.findProperty("llamaAbis") as String? ?: "arm64-v8a,x86_64")
        .split(",").map { it.trim() }
}

android {
    namespace = "com.example.enlibra_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.enlibra_mobile"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Kept in step with packages/llama_bridge/android/build.gradle.
        // 32-bit ABIs are never built: such a device cannot address enough
        // memory to hold even the 1B model.
        ndk {
            abiFilters.addAll(enlibraAbis)
        }
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
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
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                // Lets `flutter run --release` work on a fresh clone. A build
                // signed this way cannot be uploaded to Play.
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

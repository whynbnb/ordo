import java.io.File

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------------------------------------------------------------------------
// Rust 交叉编译配置：把 ordo_core 编成 Android 各 ABI 的 .so 并放入 jniLibs。
// 需要本机安装 Android NDK 以及 `cargo install cargo-ndk`。
//
// 可用 -Pordo.rustAbis=arm64-v8a 指定要编译的 ABI；默认构建三种常见 ABI。
// ---------------------------------------------------------------------------

val rustCrateDir = rootProject.projectDir.parentFile.resolve("rust")
val rustJniLibsDir = File(projectDir, "src/main/jniLibs")

// 应用版本号唯一来源：仓库根目录的 VERSION 文件（形如 1.0）。
val ordoVersionName: String =
    rootProject.projectDir.parentFile.resolve("VERSION").readText().trim()
val rustAbis: List<String> =
    (project.findProperty("ordo.rustAbis") as String?)
        ?.split(",")
        ?.map(String::trim)
        ?.filter(String::isNotEmpty)
        ?.takeIf { it.isNotEmpty() }
        ?: listOf("arm64-v8a", "armeabi-v7a", "x86_64")

android {
    namespace = "me.whynbnb.ordo"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "me.whynbnb.ordo"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = ordoVersionName

        ndk {
            // 只打包实际编译了 Rust 核心的 ABI，避免出现缺少原生库的架构。
            abiFilters += rustAbis
        }
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
    // 仅用于 FileProvider（打开文件 / 分享），与文件读取无关。
    implementation("androidx.core:core-ktx:1.15.0")

    // Shizuku：把 ADB / root 级权限借给普通应用（用于访问 Android/data 等）。
    implementation("dev.rikka.shizuku:api:13.1.5")
    implementation("dev.rikka.shizuku:provider:13.1.5")
}

flutter {
    source = "../.."
}

fun resolveCargo(): String {
    val home = System.getProperty("user.home")
    val candidates = listOf(
        System.getenv("CARGO") ?: "",
        "$home/.cargo/bin/cargo",
        "/opt/homebrew/bin/cargo",
        "/usr/local/bin/cargo",
    )
    for (candidate in candidates) {
        if (candidate.isNotEmpty() && File(candidate).canExecute()) return candidate
    }
    return "cargo"
}

val cargoNdkBuild = tasks.register<Exec>("cargoNdkBuild") {
    group = "rust"
    description = "使用 cargo-ndk 交叉编译 Rust 核心到 jniLibs"

    workingDir = rustCrateDir
    inputs.dir(File(rustCrateDir, "src"))
    inputs.file(File(rustCrateDir, "Cargo.toml"))
    outputs.dir(rustJniLibsDir)

    doFirst {
        // 清理不再需要的 ABI，避免旧产物被误打包。
        rustJniLibsDir.listFiles()?.forEach { dir ->
            if (dir.isDirectory && dir.name !in rustAbis) dir.deleteRecursively()
        }
        rustJniLibsDir.mkdirs()

        val args = mutableListOf(resolveCargo(), "ndk")
        rustAbis.forEach { abi ->
            args.add("-t")
            args.add(abi)
        }
        args.add("-o")
        args.add(rustJniLibsDir.absolutePath)
        args.add("build")
        args.add("--release")
        commandLine(args)
    }

    // 把以 shell / root 身份运行的辅助进程打包进 assets，供原生层部署到
    // /data/local/tmp 后启动。
    doLast {
        val tripleOf = mapOf(
            "arm64-v8a" to "aarch64-linux-android",
            "armeabi-v7a" to "armv7-linux-androideabi",
            "x86_64" to "x86_64-linux-android",
        )
        val assetsDir = File(projectDir, "src/main/assets/privd")
        assetsDir.mkdirs()
        rustAbis.forEach { abi ->
            val triple = tripleOf[abi] ?: return@forEach
            val binary = File(rustCrateDir, "target/$triple/release/ordo-privd")
            if (binary.exists()) {
                val destDir = File(assetsDir, abi).apply { mkdirs() }
                binary.copyTo(File(destDir, "ordo-privd"), overwrite = true)
            } else {
                logger.warn("ordo-privd 未生成，跳过：${binary.absolutePath}")
            }
        }
    }
}

tasks.matching { it.name.startsWith("merge") && it.name.endsWith("JniLibFolders") }
    .configureEach { dependsOn(cargoNdkBuild) }

tasks.matching { it.name.startsWith("merge") && it.name.endsWith("Assets") }
    .configureEach { dependsOn(cargoNdkBuild) }

tasks.matching { it.name == "preBuild" }.configureEach { dependsOn(cargoNdkBuild) }

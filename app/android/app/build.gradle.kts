import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// llama.cpp checkout for the on-device engine (release b11913, the same as the Vynilo server).
// Machine-specific: set llamaCppDir=/path/to/llama.cpp in ~/.gradle/gradle.properties
// (Flutter rewrites android/local.properties on every build). Without it the app builds
// without the on-device engine and falls back to the demo engine.
val llamaCppDir: String? = providers.gradleProperty("llamaCppDir").orNull

// Release signing key, kept outside the repository (android/key.properties is gitignored). Without
// it, release builds fall back to the debug key.
val keyProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

android {
    namespace = "com.vynilo.lyrics"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.vynilo.lyrics"
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

        if (llamaCppDir != null) {
            externalNativeBuild {
                cmake {
                    abiFilters("arm64-v8a")
                    arguments += listOf(
                        "-DLLAMA_SRC=$llamaCppDir",
                        "-DCMAKE_BUILD_TYPE=Release",
                        "-DBUILD_SHARED_LIBS=ON",
                        "-DLLAMA_BUILD_COMMON=OFF",
                        "-DLLAMA_BUILD_TESTS=OFF",
                        "-DLLAMA_BUILD_TOOLS=OFF",
                        "-DLLAMA_BUILD_EXAMPLES=OFF",
                        "-DLLAMA_BUILD_SERVER=OFF",
                        "-DLLAMA_OPENSSL=OFF",
                        "-DLLAMA_CURL=OFF",
                        "-DGGML_NATIVE=OFF",
                        "-DGGML_BACKEND_DL=ON",
                        "-DGGML_CPU_ALL_VARIANTS=ON",
                        "-DGGML_LLAMAFILE=OFF",
                        "-DGGML_OPENMP=ON",
                        // At most 2 compile jobs: llama.cpp is large and the build machine also serves.
                        "-DCMAKE_JOB_POOLS=compile=2",
                        "-DCMAKE_JOB_POOL_COMPILE=compile",
                    )
                }
            }
        }
    }

    if (llamaCppDir != null) {
        externalNativeBuild {
            cmake {
                path("src/main/cpp/CMakeLists.txt")
                version = "3.31.6"
            }
        }
    }

    packaging {
        jniLibs { useLegacyPackaging = true }
    }

    signingConfigs {
        if (keyProperties.getProperty("storeFile") != null) {
            create("release") {
                storeFile = file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // The stable Vynilo key keeps the signing fingerprint (registered with Spotify) fixed.
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
            // shared_preferences_android and path_provider_android call their Kotlin side through
            // package:jni, which R8 cannot see: a minified build strips those methods and the app
            // hangs on its first SharedPreferences read. The Dart code is AOT-compiled anyway.
            isMinifyEnabled = false
            isShrinkResources = false
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

dependencies {
    // Spotify App Remote SDK 0.8.0 (github.com/spotify/android-sdk) and the serializer it uses.
    implementation(files("libs/spotify-app-remote-release-0.8.0.aar"))
    implementation("com.google.code.gson:gson:2.11.0")
}

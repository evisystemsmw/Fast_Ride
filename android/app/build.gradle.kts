import java.util.Properties

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keyProps = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) load(f.inputStream())
}

android {
    namespace = "com.fastrider.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.fastrider.app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
    }

    signingConfigs {
        create("release") {
            // Prefer value from key.properties if it points to an existing file.
            // If it points to a filename in project root but the file exists under
            // android/, prefer that. Finally fall back to android/fastrider.jks.
            val sf = keyProps["storeFile"] as String?
            val candidates = mutableListOf<String>()
            if (sf != null && sf.isNotBlank()) {
                candidates.add(sf)
                // if sf looks like a bare filename, also try under android/
                if (!sf.contains("/") && !sf.contains("\\\\")) candidates.add("android/$sf")
            }
            candidates.add("android/fastrider.jks")
            // Also explicitly check the android/ keystore path using a File constructed
            // from the root project directory to avoid surprises with working dirs.
            // rootProject in the Android Gradle build points to the android/ directory,
            // so check for the keystore directly under that directory as `fastrider.jks`.
            val explicitAndroid = rootProject.file("fastrider.jks")
            println("[build.gradle.kts] keyProps.storeFile=${keyProps["storeFile"]} explicitAndroid.exists=${explicitAndroid.exists()} explicitAndroid.path=${explicitAndroid.absolutePath}")
            val resolvedFile = if (explicitAndroid.exists()) {
                explicitAndroid
            } else {
                candidates.map { rootProject.file(it) }.firstOrNull { it.exists() }
                    ?: rootProject.file(candidates.first())
            }
            println("[build.gradle.kts] resolved signing storeFile: ${resolvedFile.absolutePath}")
            storeFile = resolvedFile
            storePassword = keyProps["storePassword"] as String?
            keyAlias = keyProps["keyAlias"] as String?
            keyPassword = keyProps["keyPassword"] as String?
        }
    }

    buildTypes {
        debug {
            signingConfig = signingConfigs.getByName("debug")
        }
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinJvmCompile>().configureEach {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

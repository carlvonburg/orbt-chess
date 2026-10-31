// The Android app: the activities, the manifest and what needs the app itself (Custom Tabs,
// Play services' sign-in, the core's .so files, the Dropbox key, versions and signing) around
// the shared code in `app`. AGP's built-in Kotlin compiles it.
import java.util.Properties

plugins {
    id("com.android.application")
    kotlin("plugin.compose")
}

// Dropbox's app key (the OAuth client id of the owner's Dropbox app): the Gradle property
// `orbt.dropboxAppKey` (`-P`, ~/.gradle/gradle.properties) or the same key in local.properties.
// Without it the Dropbox sign-in says the build has none.
val dropboxAppKey: String = providers.gradleProperty("orbt.dropboxAppKey").orNull
    ?: rootProject.file("local.properties").takeIf { it.exists() }?.let { file ->
        Properties().apply { file.inputStream().use { load(it) } }.getProperty("orbt.dropboxAppKey")
    }
    ?: ""

android {
    namespace = "org.orbtchess.orbt"
    compileSdk { version = release(37) { minorApiLevel = 1 } }
    buildFeatures {
        buildConfig = true
    }
    defaultConfig {
        buildConfigField("String", "DROPBOX_APP_KEY", "\"$dropboxAppKey\"")
        applicationId = "org.orbtchess.orbt"
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "0.1"
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }
    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    implementation(project(":app"))
    implementation(project(":core"))
    implementation("androidx.activity:activity-compose:1.13.0")
    // Lichess and Dropbox sign-ins, Analyse on Lichess (Custom Tabs).
    implementation("androidx.browser:browser:1.8.0")
    // The splash screen (Theme.Orbt.Starting) on every Android version.
    implementation("androidx.core:core-splashscreen:1.2.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    // Google Drive sign-in (Identity's AuthorizationClient, the drive.file scope).
    implementation("com.google.android.gms:play-services-auth:21.4.0")
    // Asking for a rating in the Play Store (In-App Review).
    implementation("com.google.android.play:review:2.0.2")
}

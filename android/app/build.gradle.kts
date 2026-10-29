// The app: one Compose Multiplatform UI for Android and the desktop (Windows, Linux).
import org.jetbrains.compose.desktop.application.dsl.TargetFormat

plugins {
    kotlin("multiplatform")
    kotlin("plugin.compose")
    id("org.jetbrains.compose")
    id("com.android.application")
}

kotlin {
    jvmToolchain(17)
    androidTarget()
    jvm("desktop")

    sourceSets {
        commonMain.dependencies {
            implementation(project(":core"))
            implementation(compose.runtime)
            implementation(compose.foundation)
            implementation(compose.material3)
            implementation(compose.ui)
            implementation(compose.materialIconsExtended)
            implementation(compose.components.resources)
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
            implementation("com.squareup.okhttp3:okhttp:4.12.0")
            // The stats cache: SQLite with its own build of the library on every platform.
            implementation("androidx.sqlite:sqlite-bundled:2.6.1")
        }
        androidMain.dependencies {
            implementation("androidx.activity:activity-compose:1.10.1")
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
            // Lichess sign-in and Analyse on Lichess (Custom Tabs).
            implementation("androidx.browser:browser:1.8.0")
        }
        val desktopMain by getting {
            dependencies {
                implementation(compose.desktop.currentOs)
                implementation("org.jetbrains.kotlinx:kotlinx-coroutines-swing:1.10.2")
            }
        }
        val desktopTest by getting {
            dependencies {
                implementation(kotlin("test"))
                implementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
            }
        }
    }
}

android {
    namespace = "org.orbtchess.orbt"
    compileSdk = 36
    defaultConfig {
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

compose.desktop {
    application {
        mainClass = "org.orbtchess.orbt.MainKt"
        nativeDistributions {
            targetFormats(TargetFormat.Msi, TargetFormat.Deb)
            // The loopback redirect of the Lichess sign-in.
            modules("jdk.httpserver")
            packageName = "ORBT Chess"
            packageVersion = "0.1.0"
        }
    }
}

// Desktop tests load the host's library that core/scripts/build-android.sh puts in core/build/host.
tasks.withType<Test>().configureEach {
    systemProperty("jna.library.path", project(":core").layout.buildDirectory.dir("host").get().asFile.path)
}

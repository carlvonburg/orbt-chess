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
        }
        androidMain.dependencies {
            implementation("androidx.activity:activity-compose:1.10.1")
        }
        val desktopMain by getting {
            dependencies {
                implementation(compose.desktop.currentOs)
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
            packageName = "ORBT Chess"
            packageVersion = "0.1.0"
        }
    }
}

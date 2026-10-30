// The app: one Compose Multiplatform UI for Android and the desktop (Windows, Linux).
import org.jetbrains.compose.desktop.application.dsl.TargetFormat
import java.util.Properties

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
            implementation(compose.ui)
            implementation(compose.materialIconsExtended)
            implementation(compose.components.resources)
            // The navigation shell: bottom bar on phones, list-detail panes on wide windows,
            // window size classes, back handling, the shell's state kept across rotation.
            implementation("org.jetbrains.compose.material3:material3:1.9.0")
            implementation("org.jetbrains.compose.material3:material3-adaptive-navigation-suite:1.9.0")
            implementation("org.jetbrains.compose.material3.adaptive:adaptive:1.2.0")
            implementation("org.jetbrains.compose.material3.adaptive:adaptive-layout:1.2.0")
            implementation("org.jetbrains.compose.material3.adaptive:adaptive-navigation:1.2.0")
            implementation("org.jetbrains.compose.ui:ui-backhandler:1.9.0")
            implementation("org.jetbrains.androidx.lifecycle:lifecycle-viewmodel-compose:2.9.5")
            // Material color schemes from a seed (the app colors other than Multicolor) and
            // custom colors harmonized with them, as Android's own dynamic color makes them.
            implementation("com.materialkolor:material-kolor:4.0.5")
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
            implementation("com.squareup.okhttp3:okhttp:4.12.0")
            // The stats cache: SQLite with its own build of the library on every platform.
            implementation("androidx.sqlite:sqlite-bundled:2.6.1")
        }
        androidMain.dependencies {
            implementation("androidx.activity:activity-compose:1.10.1")
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
            // Lichess and Dropbox sign-ins, Analyse on Lichess (Custom Tabs).
            implementation("androidx.browser:browser:1.8.0")
            // Google Drive sign-in (Identity's AuthorizationClient, the drive.file scope).
            implementation("com.google.android.gms:play-services-auth:21.4.0")
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
    compileSdk = 36
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

// The core's library for this computer, which core/scripts/build-android.sh builds into
// core/build/host: the desktop app's resources for its OS and architecture (Compose's
// `appResourcesRootDir` layout, e.g. macos-arm64/, linux-x64/, windows-x64/). `run` and the
// packaged app both get them in `compose.application.resources.dir`; Main.kt points JNA there.
val hostResourcesDir = layout.buildDirectory.dir("hostResources")
val hostPlatform: String = run {
    val os = System.getProperty("os.name").lowercase()
    val arch = System.getProperty("os.arch").lowercase()
    val osId = when {
        os.contains("mac") -> "macos"
        os.contains("win") -> "windows"
        else -> "linux"
    }
    val archId = if (arch == "aarch64" || arch == "arm64") "arm64" else "x64"
    "$osId-$archId"
}
val copyHostLibrary by tasks.registering(Sync::class) {
    from(project(":core").layout.buildDirectory.dir("host"))
    into(hostResourcesDir.map { it.dir(hostPlatform) })
    doFirst {
        val host = project(":core").layout.buildDirectory.dir("host").get().asFile
        if (host.listFiles().isNullOrEmpty()) {
            throw GradleException("No core library in $host: run core/scripts/build-android.sh first.")
        }
    }
}
tasks.matching { it.name == "prepareAppResources" }.configureEach { dependsOn(copyHostLibrary) }

compose.desktop {
    application {
        mainClass = "org.orbtchess.orbt.MainKt"
        nativeDistributions {
            appResourcesRootDir.set(hostResourcesDir)
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

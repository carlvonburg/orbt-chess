// The app's shared code: one Compose Multiplatform UI for Android and the desktop (Windows,
// Linux), a Kotlin Multiplatform library that androidApp builds the Android app from, and the
// desktop app (`run`, `packageDistributionForCurrentOS`).
import org.jetbrains.compose.desktop.application.dsl.TargetFormat

plugins {
    kotlin("multiplatform")
    kotlin("plugin.compose")
    id("org.jetbrains.compose")
    id("com.android.kotlin.multiplatform.library")
}

kotlin {
    jvmToolchain(17)
    android {
        namespace = "org.orbtchess.orbt.shared"
        compileSdk { version = release(37) { minorApiLevel = 1 } }
        minSdk = 29
        // Compose resources (composeResources/) go into the Android app's assets.
        androidResources { enable = true }
    }
    jvm("desktop")

    // The UI is Material 3 Expressive (button groups, shape morphing, loading indicators, flexible
    // app bars): its experimental API everywhere, not opted into function by function.
    sourceSets.all { languageSettings.optIn("androidx.compose.material3.ExperimentalMaterial3ExpressiveApi") }

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
            implementation("org.jetbrains.compose.material3:material3:1.13.0-beta01")
            implementation("org.jetbrains.compose.material3:material3-adaptive-navigation-suite:1.13.0-beta01")
            implementation("org.jetbrains.compose.material3.adaptive:adaptive:1.3.0")
            implementation("org.jetbrains.compose.material3.adaptive:adaptive-layout:1.3.0")
            implementation("org.jetbrains.compose.material3.adaptive:adaptive-navigation:1.3.0")
            implementation("org.jetbrains.androidx.navigationevent:navigationevent-compose:1.1.0")
            implementation("org.jetbrains.androidx.lifecycle:lifecycle-viewmodel-compose:2.11.0")
            // Material color schemes from a seed (the app colors other than Multicolor) and
            // custom colors harmonized with them, as Android's own dynamic color makes them.
            implementation("com.materialkolor:material-kolor:4.0.5")
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
            implementation("com.squareup.okhttp3:okhttp:4.12.0")
            // The stats cache: SQLite with its own build of the library on every platform.
            implementation("androidx.sqlite:sqlite-bundled:2.6.1")
        }
        androidMain.dependencies {
            implementation("androidx.activity:activity-compose:1.13.0")
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
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
            // The app icon, Design/AppIcon-light.svg clipped to a rounded square (rx 224 of 1024):
            // rsvg-convert to 512 px for Linux (also the window's, Main.kt) and to 16-256 px,
            // joined by ImageMagick (`magick i16.png … i256.png orbt.ico`), for Windows.
            linux { iconFile.set(project.file("src/desktopMain/resources/orbt-icon.png")) }
            windows { iconFile.set(project.file("icons/orbt.ico")) }
        }
    }
}

// Desktop tests load the host's library that core/scripts/build-android.sh puts in core/build/host.
tasks.withType<Test>().configureEach {
    systemProperty("jna.library.path", project(":core").layout.buildDirectory.dir("host").get().asFile.path)
}

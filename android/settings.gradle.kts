// ORBT Chess for Android, Windows and Linux: one Compose Multiplatform app over the Rust core
// (README.md, Layout). `core` holds the generated Kotlin bindings; `app` is the app's shared code
// (a Kotlin Multiplatform library) and the desktop app; `androidApp` is the Android app.
pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
        google()
    }
}

dependencyResolutionManagement {
    repositories {
        mavenCentral()
        google()
    }
}

rootProject.name = "orbt"
include(":core", ":app", ":androidApp")

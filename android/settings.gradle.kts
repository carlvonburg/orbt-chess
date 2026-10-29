// ORBT Chess for Android, Windows and Linux: one Compose Multiplatform app over the Rust core
// (see FUTURE.md). `core` holds the generated Kotlin bindings and the core's native libraries;
// `app` is the app.
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
include(":core", ":app")

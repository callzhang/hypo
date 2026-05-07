// Top-level build file where you can add configuration options common to all sub-projects/modules.
plugins {
    id("com.android.application") version "8.13.1" apply false
    id("org.jetbrains.kotlin.android") version "1.9.22" apply false
    id("org.jetbrains.kotlin.plugin.serialization") version "1.9.22" apply false
    id("com.google.devtools.ksp") version "1.9.22-1.0.16" apply false
    id("com.google.dagger.hilt.android") version "2.50" apply false
}

val externalBuildRoot = System.getenv("HYPO_ANDROID_BUILD_DIR")?.takeIf { it.isNotBlank() }

if (externalBuildRoot != null) {
    layout.buildDirectory.set(file("$externalBuildRoot/root"))
}

subprojects {
    if (externalBuildRoot != null) {
        val moduleBuildPath = path.removePrefix(":").replace(':', '-')
        layout.buildDirectory.set(file("$externalBuildRoot/$moduleBuildPath"))
    }
}

tasks.register("clean", Delete::class) {
    delete(rootProject.layout.buildDirectory)
    delete(subprojects.map { it.layout.buildDirectory })
}

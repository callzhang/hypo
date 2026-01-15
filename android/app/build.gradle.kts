import java.util.Properties
import org.gradle.api.file.DuplicatesStrategy

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.serialization")
    id("com.google.devtools.ksp")
    id("com.google.dagger.hilt.android")
    id("io.sentry.android.gradle")
    id("jacoco")
}

jacoco {
    toolVersion = "0.8.11"
}

tasks.register<JacocoReport>("jacocoTestReport") {
    dependsOn("testDebugUnitTest")

    reports {
        xml.required.set(true)
        html.required.set(true)
    }

    val fileFilter = listOf(
        "**/R.class", "**/R$*.class", "**/BuildConfig.*", "**/Manifest*.*", "**/*Test*.*", "android/**/*.*",
        "**/*_MembersInjector.class",
        "**/Dagger*Component.class",
        "**/Dagger*Component\$Builder.class",
        "**/*User_Factory.class",
        "**/*_Factory.class",
        "**/*_HiltModules*.*",
        "**/Hilt_*",
        "**/*_Impl*",
        "**/*TypeAdapter*"
    )
    
    val kotlinClasses = fileTree("${project.layout.buildDirectory.get()}/intermediates/classes/debug/transformDebugClassesWithAsm/dirs") {
        exclude(fileFilter)
    }
    val javaClasses = fileTree("${project.layout.buildDirectory.get()}/intermediates/javac/debug/classes") {
        exclude(fileFilter)
    }

    sourceDirectories.setFrom(files("src/main/java"))
    classDirectories.setFrom(files(kotlinClasses, javaClasses))
    executionData.setFrom(fileTree(project.buildDir).include(
        "jacoco/testDebugUnitTest.exec",
        "outputs/unit_test_code_coverage/debugUnitTest/testDebugUnitTest.exec"
    ))
}

// Read version from centralized VERSION file
val versionFile = rootProject.file("../VERSION")
require(versionFile.exists()) {
    "VERSION file not found at ${versionFile.absolutePath}. Create it with the current version (e.g., 1.0.5)."
}

val projectVersion = versionFile.readText().trim()
require(projectVersion.isNotEmpty()) {
    "VERSION file is empty. Set a valid version (e.g., 1.0.5)."
}

// Parse version to get versionCode (e.g., 1.1.0 -> 10100)
// versionCode must be >= 1 for Android apps
val versionParts = projectVersion.split(".")
require(versionParts.size >= 3) {
    "Invalid version format: '$projectVersion'. Expected format: MAJOR.MINOR.PATCH (e.g., 1.0.5)."
}

val major = versionParts[0].toIntOrNull() ?: 0
val minor = versionParts[1].toIntOrNull() ?: 0
val patch = versionParts[2].toIntOrNull() ?: 0

// Robust versionCode calculation: MAJOR * 10000 + MINOR * 100 + PATCH
// This allows for up to 99 minors and 99 patches per minor.
// Example: 1.0.5 -> 10005, 1.1.0 -> 10100, 2.0.0 -> 20000
val versionCodeValue = major * 10000 + minor * 100 + patch
require(versionCodeValue >= 1) {
    "Invalid versionCode: $versionCodeValue. Android versionCode must be >= 1."
}

android {
    namespace = "com.hypo.clipboard"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.hypo.clipboard"
        minSdk = 26
        targetSdk = 34
        versionCode = versionCodeValue
        versionName = projectVersion

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        vectorDrawables {
            useSupportLibrary = true
        }

        buildConfigField("String", "RELAY_WS_URL", "\"wss://hypo.fly.dev/ws\"")
        // No certificate pinning for relay - standard TLS verification is sufficient
        // Certificate pinning causes issues when certificates change and is overkill for a relay service
        buildConfigField("String", "RELAY_CERT_FINGERPRINT", "\"\"")
        buildConfigField("String", "RELAY_ENVIRONMENT", "\"production\"")
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            signingConfig = signingConfigs.getByName("debug") // TODO: Replace with release signing
            // Limit native libraries to arm64-v8a only (saves ~15MB)
            // arm64-v8a covers all modern Android devices (Android 5.0+, API 21+)
            // x86/x86_64 are mainly for emulators and can be excluded from release builds
            ndk {
                abiFilters += listOf("arm64-v8a")
            }
        }
        debug {
            isDebuggable = true
            enableUnitTestCoverage = true
            // Removed applicationIdSuffix to allow debug and release builds to share the same database
            // Note: This means debug and release cannot be installed simultaneously
            versionNameSuffix = "-debug"
            // Keep all ABIs for debug builds to support emulator testing
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
        freeCompilerArgs += listOf(
            "-opt-in=kotlin.RequiresOptIn",
            "-opt-in=kotlinx.coroutines.ExperimentalCoroutinesApi",
            "-opt-in=kotlinx.coroutines.FlowPreview"
        )
        // Prevent duplicate ComposableSingletons classes
        allWarningsAsErrors = false
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    composeOptions {
        kotlinCompilerExtensionVersion = "1.5.10"
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.extensions.configure(JacocoTaskExtension::class.java) {
                    isIncludeNoLocationClasses = true
                    excludes = listOf("jdk.internal.*")
                }
            }
        }
    }
}

// Sentry configuration
// Load .env file if it exists
val envFile = rootProject.file("../.env")
val envProperties = Properties()
if (envFile.exists()) {
    envFile.inputStream().use { envProperties.load(it) }
}

// Configure Sentry - only enable uploads if auth token is provided
val sentryAuthToken = System.getenv("SENTRY_AUTH_TOKEN") 
    ?: envProperties.getProperty("SENTRY_AUTH_TOKEN", "")

sentry {
    // Generates a source bundle and uploads your source code to Sentry
    // This enables source context, allowing you to see your source
    // code as part of your stack traces in Sentry
    includeSourceContext = true
    
    org = "stardust-dm"
    projectName = "clipboard"
    
    // Only configure uploads if auth token is provided (disable in CI without token)
    if (sentryAuthToken.isNotEmpty()) {
        authToken = sentryAuthToken
    // Automatically upload ProGuard/R8 mapping files
    uploadNativeSymbols = true
    includeNativeSources = true
        autoUploadProguardMapping = true
    } else {
        // Disable all uploads when no token is available
        uploadNativeSymbols = false
        includeNativeSources = false
        autoUploadProguardMapping = false
        // Set empty token to prevent plugin from trying to upload
        authToken = ""
    }
}

// Skip Sentry upload tasks when no auth token is available
tasks.configureEach {
    if (name.startsWith("uploadSentry") || name.startsWith("sentryBundle")) {
        val sentryAuthToken = System.getenv("SENTRY_AUTH_TOKEN") 
            ?: rootProject.file("../.env").let { file ->
                if (file.exists()) {
                    val props = Properties()
                    file.inputStream().use { props.load(it) }
                    props.getProperty("SENTRY_AUTH_TOKEN", "")
                } else {
                    ""
                }
            }
        if (sentryAuthToken.isEmpty()) {
            enabled = false
        }
    }
}

androidComponents {
    beforeVariants(selector().withBuildType("release")) { variantBuilder ->
        (variantBuilder as? com.android.build.api.variant.HasHostTestsBuilder)?.hostTests?.get(com.android.build.api.variant.HostTestBuilder.UNIT_TEST_TYPE)?.enable = false
    }
}

    dependencies {
        // WebSocket server for LAN (handles framing correctly)
        implementation("org.java-websocket:Java-WebSocket:1.5.4")
        // AndroidX Core
        implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.7.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.7.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.7.0")
    implementation("androidx.activity:activity-compose:1.8.2")

    // Compose BOM
    implementation(platform("androidx.compose:compose-bom:2024.02.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    // Note: R8/ProGuard will remove unused icons in release builds
    implementation("com.google.android.material:material:1.11.0")

    // Navigation
    implementation("androidx.navigation:navigation-compose:2.7.6")

    // Room
    implementation("androidx.room:room-runtime:2.6.1")
    implementation("androidx.room:room-ktx:2.6.1")
    ksp("androidx.room:room-compiler:2.6.1")
    implementation("androidx.room:room-paging:2.6.1")

    // Paging
    implementation("androidx.paging:paging-runtime-ktx:3.2.1")

    // DataStore
    implementation("androidx.datastore:datastore-preferences:1.0.0")

    // Work Manager
    implementation("androidx.work:work-runtime-ktx:2.9.0")

    // Hilt
    implementation("com.google.dagger:hilt-android:2.50")
    ksp("com.google.dagger:hilt-compiler:2.50")
    implementation("androidx.hilt:hilt-navigation-compose:1.1.0")
    implementation("androidx.hilt:hilt-work:1.1.0")
    ksp("androidx.hilt:hilt-compiler:1.1.0")

    // Networking
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.squareup.okhttp3:logging-interceptor:4.12.0")

    // Serialization
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.2")

    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")

    // Security
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    implementation("com.google.crypto.tink:tink-android:1.13.0")

    // Barcode scanning removed
    // Pairing now uses LAN auto-discovery and manual code entry

    // Accompanist (Permissions) - REMOVED: Not used
    // Coil (Image Loading) - REMOVED: Not used

    // Sentry (Crash Reporting)
    implementation("io.sentry:sentry-android:7.5.0")

    // Testing
    testImplementation(kotlin("test"))
    testImplementation(kotlin("reflect"))
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.7.3")
    testImplementation("io.mockk:mockk:1.13.9")
    testImplementation("app.cash.turbine:turbine:1.0.0")
    testImplementation("androidx.test:core:1.5.0")
    testImplementation("org.robolectric:robolectric:4.11.1")
    
    androidTestImplementation("androidx.test.ext:junit:1.1.5")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.5.1")
    androidTestImplementation(platform("androidx.compose:compose-bom:2024.02.00"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    
    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}

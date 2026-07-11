// The RichText library module. A 1:1 semantic port of Sources/RichText (Swift): the model, markdown parser,
// autolinker, URL policy, syntax highlighter, and HTML/Markdown serializers are pure Kotlin (JVM-testable);
// the Compose renderer reproduces the TextKit visual design. Runtime dependencies are limited to the
// AndroidX/Compose baseline + kotlinx-coroutines + AsyncImageCache (for inline/block images). No third-party
// markdown libraries.

plugins {
    // AGP 9.2 ships built-in Kotlin support (it registers the `kotlin` extension), so the standalone
    // org.jetbrains.kotlin.android plugin is neither applied nor needed - only the Compose compiler plugin.
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.compose)
}

// Coordinate for consumption as a Gradle composite build: ActionUIAndroid declares a dependency on
// `com.abracode:richtext` and includeBuild substitutes this project for it (see settings.gradle.kts). The group
// must be set for that automatic substitution to match.
group = "com.abracode"
version = "0.1.0"

android {
    namespace = "com.abracode.richtext"
    compileSdk = 36

    defaultConfig {
        minSdk = 31
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        consumerProguardFiles("consumer-rules.pro")
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

    buildFeatures {
        compose = true
    }

    // Stage C cross-platform parity fixtures live at the repo root (Fixtures/markdown + Fixtures/expected),
    // shared byte-for-byte with the Swift emitter. Mount them as androidTest assets so the instrumented parity
    // suite reads THE SAME files the Swift side emitted - one fixture set, two consumers. This module is at
    // android/richtext, so ../../Fixtures is the repo root Fixtures/. (Directory may not exist until Stage C;
    // an absent assets dir contributes nothing and does not fail the build.)
    sourceSets {
        getByName("androidTest") {
            assets.srcDir("../../Fixtures")
        }
    }

    // The pure-logic port (parser/model/serializers/highlighter/policy) is 100% platform-free and runs as fast
    // JVM unit tests. It never touches android.* APIs, so default-value stubbing stays off.
    testOptions {
        unitTests.isReturnDefaultValues = false
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.androidx.core.ktx)

    // Inline / block image loading - the exact dependency the Swift package has (resolved via the sibling
    // composite build declared in settings.gradle.kts).
    implementation(libs.asyncimagecache)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.material3)

    // JVM unit tests (pure logic: parser, model, serializers, highlighter, URL policy).
    testImplementation(libs.junit)

    // Instrumented tests (Compose renderer structure, interaction, colors; fixture parity).
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.core)
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
}

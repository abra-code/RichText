// The demo app module. Mirrors Demo/ (the SwiftUI demo): a document gallery, a streaming simulator, and
// theme/engine toggles. Stage A ships a minimal shell that exercises the Compose toolchain end-to-end;
// Stage F fills in the screens.

plugins {
    // Built-in Kotlin (AGP 9.2) + the Compose compiler plugin; no standalone kotlin.android plugin.
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.abracode.richtext.demo"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.abracode.richtext.demo"
        minSdk = 31
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
    }

    // Bundle the shared Fixtures/markdown corpus as demo assets so the gallery renders the full fixture set -
    // the same documents the Stage C parity suite pins. android/demo -> ../../Fixtures/markdown is the repo corpus.
    sourceSets {
        getByName("main") {
            assets.srcDir("../../Fixtures/markdown")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(project(":richtext"))

    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.ktx)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.ui.tooling.preview)
    debugImplementation(libs.androidx.compose.ui.tooling)
}

// Gradle settings for the self-contained Android build of RichText.
//
// This build is consumed by ActionUIAndroid as a composite build:
//   includeBuild("../RichText/android")
// which substitutes the `com.abracode:richtext` module in place of any binary dependency. Keeping the build
// self-contained (its own settings + wrapper) means it also builds and tests standalone.
//
// RichText itself pulls in AsyncImageCache the same way the Swift package does - via a sibling composite build,
// so the `com.abracode:asyncimagecache` dependency in :richtext resolves to the local source project instead of
// a published artifact.

pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

// The RichText android build lives at RichText/android; AsyncImageCache's android build is a sibling repo at
// ../AsyncImageCache/android, i.e. ../../AsyncImageCache/android relative to this settings file.
includeBuild("../../AsyncImageCache/android")

rootProject.name = "RichText"
include(":richtext")
include(":demo")

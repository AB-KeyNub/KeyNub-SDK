pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositories {
        mavenCentral()
    }
}

rootProject.name = "keynub-licdongle-kotlin-samples"

// Inside a clone of the SDK repository the samples build against the library's sources next door; elsewhere they
// use the published package.
if (file("../../bindings/kotlin/build.gradle.kts").isFile) {
    includeBuild("../../bindings/kotlin")
}

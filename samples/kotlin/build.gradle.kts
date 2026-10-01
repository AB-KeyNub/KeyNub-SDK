// The two samples, as JVM programs:
//
//     gradle verifyAndRead
//     gradle rotateWriteKey --args="keys/keynub-shipping-writeauth.key.der my-key.der"
//
// Run from samples/kotlin in a clone, they find the native library in the clone's natives/<platform>/.
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    kotlin("jvm") version "2.4.20"
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    implementation("com.keynub:keynub-licdongle-kotlin:1.1.1")
}

for ((task, main) in listOf("verifyAndRead" to "VerifyAndReadKt", "rotateWriteKey" to "RotateWriteKeyKt")) {
    tasks.register<JavaExec>(task) {
        group = "samples"
        classpath = sourceSets["main"].runtimeClasspath
        mainClass.set(main)
        workingDir = projectDir
    }
}

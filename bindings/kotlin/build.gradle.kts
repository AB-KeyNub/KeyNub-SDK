import org.gradle.plugins.signing.SigningExtension
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.dsl.KotlinVersion
import org.jetbrains.kotlin.gradle.plugin.mpp.KotlinNativeTarget
import org.jetbrains.kotlin.gradle.targets.native.tasks.KotlinNativeTest

plugins {
    kotlin("multiplatform") version "2.4.20"
    id("com.vanniktech.maven.publish") version "0.37.0"
}

val hostIsMac = System.getProperty("os.name").lowercase().startsWith("mac")

kotlin {
    jvm {
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_17)
        }
    }

    // Kotlin/Native targets: the flat C API through a small C shim (src/nativeInterop/cinterop/flat.def)
    // that loads the native library at run time. Apple targets build on a macOS host only.
    val nativeTargets = mutableListOf<KotlinNativeTarget>(mingwX64(), linuxX64(), linuxArm64())
    if (hostIsMac) {
        nativeTargets += macosArm64()
    }
    nativeTargets.forEach { target ->
        target.compilations.getByName("main").cinterops.create("flat") {
            definitionFile.set(project.file("src/nativeInterop/cinterop/flat.def"))
            packageName("com.keynub.licdongle.kotlin.cinterop")
        }
    }

    compilerOptions {
        apiVersion.set(KotlinVersion.KOTLIN_2_2)
        languageVersion.set(KotlinVersion.KOTLIN_2_2)
        allWarningsAsErrors.set(true)
        freeCompilerArgs.add("-Xexpect-actual-classes")
    }

    sourceSets {
        jvmMain.dependencies {
            implementation("net.java.dev.jna:jna:5.14.0")
        }
        commonTest.dependencies {
            implementation(kotlin("test"))
        }
        matching { !it.name.startsWith("common") && !it.name.startsWith("jvm") }.configureEach {
            languageSettings.optIn("kotlinx.cinterop.ExperimentalForeignApi")
        }
    }
}

// The C ABI stand-in for the tests: bindings/flat/licd_flat.c over bindings/julia/test/stub/licd_stub.c, one
// imaginary dongle held in memory, compiled with the first C compiler found of cc, gcc, clang, zig cc and cl.
// KEYNUB_LICDONGLE_FLAT_LIBRARY names an already compiled stand-in instead; KEYNUB_SDK_ROOT names the SDK sources
// when the project is not inside a clone.
val standInLibrary: Provider<String> = providers.provider {
    System.getenv("KEYNUB_LICDONGLE_FLAT_LIBRARY")?.takeIf { it.isNotEmpty() } ?: buildStandIn()
}

fun sdkRoot(): File {
    System.getenv("KEYNUB_SDK_ROOT")?.takeIf { it.isNotEmpty() }?.let { return File(it) }
    return generateSequence(projectDir.absoluteFile) { it.parentFile }
        .firstOrNull { File(it, "bindings/flat/licd_flat.c").isFile }
        ?: error("the SDK sources were not found above the project; set KEYNUB_SDK_ROOT")
}

fun buildStandIn(): String {
    val root = sdkRoot()
    val os = System.getProperty("os.name").lowercase()
    val windows = os.startsWith("windows")
    val dir = layout.buildDirectory.dir("standin").get().asFile.apply { mkdirs() }
    // Not the library's own name: macOS dyld searches DYLD_LIBRARY_PATH by leaf name.
    val out = File(
        dir,
        when {
            windows -> "keynub_licdongle_flat_standin.dll"
            os.startsWith("mac") -> "libkeynub_licdongle_flat_standin.dylib"
            else -> "libkeynub_licdongle_flat_standin.so"
        },
    )
    val core = File(root, "core/include")
    val include = if (File(core, "licdongle.h").isFile) core else File(root, "include")
    val sources = listOf(File(root, "bindings/flat/licd_flat.c"), File(root, "bindings/julia/test/stub/licd_stub.c"))
    val gcc = listOf("-shared", "-O1", "-DLICD_BUILD_SHARED", "-DLICDF_BUILD_SHARED", "-I$include",
        "-I${File(root, "bindings/flat")}", "-o", out.path) + sources.map { it.path } +
        (if (windows) emptyList() else listOf("-fPIC"))
    val cl = listOf("/nologo", "/LD", "/O1", "/DLICD_BUILD_SHARED", "/DLICDF_BUILD_SHARED", "/I$include",
        "/I${File(root, "bindings/flat")}", "/Fe:${out.path}") + sources.map { it.path }
    val commands = listOf(listOf("cc") + gcc, listOf("gcc") + gcc, listOf("clang") + gcc, listOf("zig", "cc") + gcc,
        listOf("cl") + cl)
    for (command in commands) {
        val ok = try {
            val p = ProcessBuilder(command).directory(dir).redirectErrorStream(true).start()
            p.inputStream.readAllBytes()
            p.waitFor() == 0
        } catch (e: java.io.IOException) {
            false
        }
        if (ok && out.isFile) return out.path
    }
    error("the C ABI stand-in could not be compiled: no C compiler (cc, gcc, clang, zig cc, cl) on the path")
}

tasks.withType<Test>().configureEach {
    environment("KEYNUB_LICDONGLE_FLAT_LIBRARY", standInLibrary.get())
    testLogging {
        showStandardStreams = true
    }
}

tasks.withType<KotlinNativeTest>().configureEach {
    environment("KEYNUB_LICDONGLE_FLAT_LIBRARY", standInLibrary.get())
    testLogging {
        showStandardStreams = true
    }
}

mavenPublishing {
    publishToMavenCentral(automaticRelease = false)
    // Signed with the local gpg (signing.gnupg.keyName in the Gradle properties) when a release is published.
    if (providers.gradleProperty("signing.gnupg.keyName").isPresent) {
        signAllPublications()
        extensions.configure<SigningExtension> { useGpgCmd() }
    }
    coordinates("com.keynub", "keynub-licdongle-kotlin", version.toString())
    pom {
        name.set("keynub-licdongle-kotlin")
        description.set(
            "Kotlin Multiplatform client for the KeyNub USB license dongle: prove that a dongle is genuine, read " +
                "and write its license records, read and increment its counters, and encrypt data that only a " +
                "dongle can decrypt. Over the SDK's flat C API; JVM and Kotlin/Native.",
        )
        url.set("https://www.keynub.com/developers/kotlin/")
        licenses {
            license {
                name.set("Apache-2.0")
                url.set("https://www.apache.org/licenses/LICENSE-2.0")
                distribution.set("repo")
            }
        }
        organization {
            name.set("KeyNub")
            url.set("https://www.keynub.com")
        }
        developers {
            developer {
                name.set("KeyNub")
                organization.set("KeyNub")
                organizationUrl.set("https://www.keynub.com")
            }
        }
        scm {
            connection.set("scm:git:https://github.com/AB-KeyNub/KeyNub-SDK.git")
            developerConnection.set("scm:git:ssh://git@github.com/AB-KeyNub/KeyNub-SDK.git")
            url.set("https://github.com/AB-KeyNub/KeyNub-SDK")
        }
    }
}

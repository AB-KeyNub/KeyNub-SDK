package com.keynub.licdongle.kotlin

import kotlin.experimental.ExperimentalNativeApi

/** The operating-system calls behind [Host], one implementation per platform family. */
internal expect object NativeOs {
    val separator: Char
    fun environment(name: String): String?
    fun isFile(path: String): Boolean
    fun currentDirectory(): String?

    /** The full path of the running executable, when it is known. */
    fun executablePath(): String?
}

@OptIn(ExperimentalNativeApi::class)
internal actual object Host {
    private val family = Platform.osFamily
    private val cpu = when (Platform.cpuArchitecture) {
        CpuArchitecture.X64 -> "x64"
        CpuArchitecture.ARM64 -> "arm64"
        CpuArchitecture.X86 -> "x86"
        else -> Platform.cpuArchitecture.name.lowercase()
    }

    actual val nativeFolder: String = when (family) {
        OsFamily.WINDOWS -> "win-$cpu"
        OsFamily.MACOSX -> "osx-$cpu"
        else -> "linux-$cpu"
    }

    actual val libraryFileName: String = when (family) {
        OsFamily.WINDOWS -> "keynub_licdongle_flat.dll"
        OsFamily.MACOSX -> "libkeynub_licdongle_flat.dylib"
        else -> "libkeynub_licdongle_flat.so"
    }

    actual fun environment(name: String): String? = NativeOs.environment(name)
    actual fun isFile(path: String): Boolean = NativeOs.isFile(path)
    actual fun currentDirectory(): String? = NativeOs.currentDirectory()
    actual fun programDirectory(): String? = NativeOs.executablePath()?.let { parent(it) }

    actual fun parent(path: String): String? {
        val trimmed = path.trimEnd('/', NativeOs.separator)
        val cut = maxOf(trimmed.lastIndexOf('/'), trimmed.lastIndexOf(NativeOs.separator))
        if (cut < 0) return null
        val parent = trimmed.substring(0, cut)
        return when {
            parent.isEmpty() -> if (cut == 0 && trimmed.length > 1) trimmed.substring(0, 1) else null
            parent.length == 2 && parent[1] == ':' -> parent + NativeOs.separator
            else -> parent
        }
    }

    actual fun join(directory: String, vararg names: String): String =
        names.fold(directory.trimEnd('/', NativeOs.separator)) { d, n -> d + NativeOs.separator + n }
}

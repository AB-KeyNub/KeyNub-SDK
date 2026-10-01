package com.keynub.licdongle.kotlin

import kotlinx.cinterop.ByteVar
import kotlinx.cinterop.UIntVar
import kotlinx.cinterop.alloc
import kotlinx.cinterop.allocArray
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.toKString
import kotlinx.cinterop.value
import platform.darwin._NSGetExecutablePath
import platform.posix.PATH_MAX
import platform.posix.S_IFMT
import platform.posix.S_IFREG
import platform.posix.getcwd
import platform.posix.getenv
import platform.posix.stat

internal actual object NativeOs {
    actual val separator: Char = '/'

    actual fun environment(name: String): String? = getenv(name)?.toKString()

    actual fun isFile(path: String): Boolean = memScoped {
        val st = alloc<stat>()
        stat(path, st.ptr) == 0 && (st.st_mode.toInt() and S_IFMT) == S_IFREG
    }

    actual fun currentDirectory(): String? = memScoped {
        val buffer = allocArray<ByteVar>(PATH_MAX)
        getcwd(buffer, PATH_MAX.toULong())?.toKString()
    }

    actual fun executablePath(): String? = memScoped {
        val size = alloc<UIntVar>()
        size.value = (PATH_MAX + 1).toUInt()
        val buffer = allocArray<ByteVar>(PATH_MAX + 1)
        if (_NSGetExecutablePath(buffer, size.ptr) == 0) buffer.toKString() else null
    }
}

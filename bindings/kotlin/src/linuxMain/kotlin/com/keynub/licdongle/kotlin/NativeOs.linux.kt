package com.keynub.licdongle.kotlin

import kotlinx.cinterop.ByteVar
import kotlinx.cinterop.alloc
import kotlinx.cinterop.allocArray
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.readBytes
import kotlinx.cinterop.toKString
import platform.posix.PATH_MAX
import platform.posix.S_IFMT
import platform.posix.S_IFREG
import platform.posix.getcwd
import platform.posix.getenv
import platform.posix.readlink
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
        val buffer = allocArray<ByteVar>(PATH_MAX + 1)
        val n = readlink("/proc/self/exe", buffer, PATH_MAX.toULong()).toInt()
        if (n <= 0) null else buffer.readBytes(n).decodeToString()
    }
}

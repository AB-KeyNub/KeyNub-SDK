package com.keynub.licdongle.kotlin

import kotlinx.cinterop.UShortVar
import kotlinx.cinterop.allocArray
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.toKString
import platform.windows.FILE_ATTRIBUTE_DIRECTORY
import platform.windows.GetCurrentDirectoryW
import platform.windows.GetEnvironmentVariableW
import platform.windows.GetFileAttributesW
import platform.windows.GetModuleFileNameW
import platform.windows.INVALID_FILE_ATTRIBUTES

internal actual object NativeOs {
    actual val separator: Char = '\\'

    actual fun environment(name: String): String? = memScoped {
        val size = 32768
        val buffer = allocArray<UShortVar>(size)
        val n = GetEnvironmentVariableW(name, buffer, size.toUInt()).toInt()
        if (n <= 0 || n >= size) null else buffer.toKString()
    }

    actual fun isFile(path: String): Boolean {
        val attributes = GetFileAttributesW(path)
        return attributes != INVALID_FILE_ATTRIBUTES && (attributes and FILE_ATTRIBUTE_DIRECTORY.toUInt()) == 0u
    }

    actual fun currentDirectory(): String? = memScoped {
        val size = 32768
        val buffer = allocArray<UShortVar>(size)
        val n = GetCurrentDirectoryW(size.toUInt(), buffer).toInt()
        if (n <= 0 || n >= size) null else buffer.toKString()
    }

    actual fun executablePath(): String? = memScoped {
        val size = 32768
        val buffer = allocArray<UShortVar>(size)
        val n = GetModuleFileNameW(null, buffer, size.toUInt()).toInt()
        if (n <= 0 || n >= size) null else buffer.toKString()
    }
}

/// Where the native library (`keynub_licdongle_flat`) comes from.
///
/// The path given to `setLibraryPath`, then `KEYNUB_LICDONGLE_FLAT_LIBRARY` in
/// the environment, then `natives/<platform>/` of an SDK clone from the
/// executable's folder and the working directory upwards, then the bare file
/// name for the system loader. A process loads the library once.
module keynub.licdongle.library;

import core.sync.mutex : Mutex;
import std.algorithm.searching : canFind;
import std.array : join;
import std.conv : to;
import std.file : exists, getcwd, isFile, thisExePath;
import std.path : buildPath, dirName;
import std.process : environment;
import std.string : fromStringz, toStringz;

import keynub.licdongle.flat;

version (Windows)
{
    import core.sys.windows.winbase : FreeLibrary, GetLastError, GetProcAddress, LoadLibraryA;
    import core.sys.windows.windef : HMODULE;

    private alias LibHandle = HMODULE;
}
else
{
    import core.sys.posix.dlfcn : dlclose, dlerror, dlopen, dlsym, RTLD_LOCAL, RTLD_NOW;

    private alias LibHandle = void*;
}

/// The native library could not be loaded, or does not fit.
class LibraryException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}

/// The environment variable that names the library file.
enum libraryEnvironmentVariable = "KEYNUB_LICDONGLE_FLAT_LIBRARY";

private immutable string[] nativeFolders = [
    "win-x64", "win-x86", "win-arm64", "linux-x64", "linux-arm64", "osx-x64", "osx-arm64"
];

private __gshared Mutex lock;
private __gshared Api table;
private __gshared bool loaded;
private __gshared string loadedPath;
private __gshared string chosenPath;

shared static this()
{
    lock = new Mutex;
}

/// Names the library file to load. Call it before the first dongle call.
void setLibraryPath(string path)
{
    lock.lock();
    scope (exit)
        lock.unlock();
    if (loaded && loadedPath != path)
        throw new LibraryException("the KeyNub library is already loaded from " ~ loadedPath
                ~ "; a process loads it once");
    chosenPath = path;
}

/// The path in use, or the first candidate when nothing is loaded yet.
string libraryPath()
{
    lock.lock();
    scope (exit)
        lock.unlock();
    return loaded ? loadedPath : candidates()[0];
}

/// The path of the loaded library; `null` before the first call.
string loadedLibraryPath()
{
    lock.lock();
    scope (exit)
        lock.unlock();
    return loaded ? loadedPath : null;
}

/// The library's file name on this operating system.
string libraryBasename()
{
    version (Windows)
        return "keynub_licdongle_flat.dll";
    else version (OSX)
        return "libkeynub_licdongle_flat.dylib";
    else
        return "libkeynub_licdongle_flat.so";
}

/// The paths tried, in order.
string[] candidates()
{
    if (chosenPath.length)
        return [chosenPath];
    auto fromEnvironment = environment.get(libraryEnvironmentVariable, "");
    if (fromEnvironment.length)
        return [fromEnvironment];
    auto base = libraryBasename();
    string[] found;
    foreach (start; startFolders())
    {
        for (string dir = start;; dir = dirName(dir))
        {
            foreach (folder; nativeFolders)
            {
                auto path = buildPath(dir, "natives", folder, base);
                if (!found.canFind(path) && exists(path) && isFile(path))
                    found ~= path;
            }
            if (dirName(dir) == dir)
                break;
        }
    }
    return found ~ base;
}

private string[] startFolders()
{
    string[] folders;
    try
        folders ~= dirName(thisExePath());
    catch (Exception)
    {
    }
    try
    {
        auto cwd = getcwd();
        if (!folders.canFind(cwd))
            folders ~= cwd;
    }
    catch (Exception)
    {
    }
    return folders;
}

/// The function table, loading the library on the first call.
package Api* api()
{
    lock.lock();
    scope (exit)
        lock.unlock();
    if (!loaded)
        load();
    return &table;
}

private void load()
{
    string[] reasons;
    foreach (path; candidates())
    {
        string why;
        if (tryLoad(path, why))
        {
            loaded = true;
            loadedPath = path;
            return;
        }
        reasons ~= path ~ " (" ~ why ~ ")";
    }
    throw new LibraryException("cannot load the KeyNub library; tried " ~ reasons.join(", "));
}

private bool tryLoad(string path, out string why)
{
    auto lib = openLibrary(path, why);
    if (lib is null)
        return false;
    Api fresh;
    foreach (i, ref field; fresh.tupleof)
    {
        enum symbol = __traits(getAttributes, Api.tupleof[i])[0].name;
        auto address = lookup(lib, symbol);
        if (address is null)
        {
            closeLibrary(lib);
            why = "does not export " ~ symbol;
            return false;
        }
        field = cast(typeof(field)) address;
    }
    table = fresh;
    return true;
}

private LibHandle openLibrary(string path, out string why)
{
    version (Windows)
    {
        auto handle = LoadLibraryA(path.toStringz);
        if (handle is null)
            why = "LoadLibrary error " ~ to!string(GetLastError());
        return handle;
    }
    else
    {
        auto handle = dlopen(path.toStringz, RTLD_NOW | RTLD_LOCAL);
        if (handle is null)
        {
            auto text = dlerror();
            why = text is null ? "dlopen failed" : fromStringz(text).idup;
        }
        return handle;
    }
}

private void* lookup(LibHandle lib, string symbol)
{
    version (Windows)
        return cast(void*) GetProcAddress(lib, symbol.toStringz);
    else
        return dlsym(lib, symbol.toStringz);
}

private void closeLibrary(LibHandle lib)
{
    version (Windows)
        FreeLibrary(lib);
    else
        dlclose(lib);
}

unittest
{
    // The bare file name is always the last resort.
    auto all = candidates();
    assert(all.length >= 1);
    assert(all[$ - 1] == libraryBasename() || all[0] == chosenPath
            || all[0] == environment.get(libraryEnvironmentVariable, ""));
}

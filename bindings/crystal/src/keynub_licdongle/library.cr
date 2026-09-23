# Where the native library (`keynub_licdongle_flat`) comes from.
#
# The path given to `KeyNub::LicDongle.library_path=`, then
# `KEYNUB_LICDONGLE_FLAT_LIBRARY` in the environment, then `natives/<platform>/`
# of an SDK clone from the executable's folder and the working directory
# upwards, then the `natives/` folder of the repository this shard was
# installed from, then the bare file name for the system loader. A process
# loads the library once.
require "./flat"

{% if flag?(:win32) %}
  # :nodoc:
  lib LibKeyNubKernel32
    fun LoadLibraryW(file_name : UInt16*) : Void*
    fun GetProcAddress(module_ : Void*, proc_name : UInt8*) : Void*
    fun FreeLibrary(module_ : Void*) : Int32
    fun GetLastError : UInt32
  end
{% end %}

module KeyNub::LicDongle
  # The native library could not be loaded, or does not fit.
  class LibraryError < Exception
  end

  # The environment variable that names the library file.
  LIBRARY_ENVIRONMENT_VARIABLE = "KEYNUB_LICDONGLE_FLAT_LIBRARY"

  # :nodoc:
  NATIVE_FOLDERS = %w(win-x64 win-x86 win-arm64 linux-x64 linux-arm64 osx-x64 osx-arm64)

  # :nodoc:
  # The repository root this file was compiled from: a clone, or the checkout
  # shards installs under lib/.
  SHARD_ROOT = {{ "#{__DIR__.id}/../../../.." }}

  @@lock = Mutex.new
  @@api : Flat::Api? = nil
  @@loaded_path : String? = nil
  @@chosen_path : String? = nil

  # Names the library file to load. Call it before the first dongle call.
  def self.library_path=(path : String) : String
    @@lock.synchronize do
      if (loaded = @@loaded_path) && loaded != path
        raise LibraryError.new("the KeyNub library is already loaded from #{loaded}; a process loads it once")
      end
      @@chosen_path = path
    end
  end

  # The path in use, or the first candidate when nothing is loaded yet.
  def self.library_path : String
    @@lock.synchronize { @@loaded_path || library_candidates.first }
  end

  # The path of the loaded library; nil before the first call.
  def self.loaded_library_path : String?
    @@lock.synchronize { @@loaded_path }
  end

  # The library's file name on this operating system.
  def self.library_basename : String
    {% if flag?(:win32) %}
      "keynub_licdongle_flat.dll"
    {% elsif flag?(:darwin) %}
      "libkeynub_licdongle_flat.dylib"
    {% else %}
      "libkeynub_licdongle_flat.so"
    {% end %}
  end

  # The paths tried, in order.
  def self.library_candidates : Array(String)
    if chosen = @@chosen_path
      return [chosen]
    end
    if (from_environment = ENV[LIBRARY_ENVIRONMENT_VARIABLE]?) && !from_environment.empty?
      return [from_environment]
    end
    base = library_basename
    found = [] of String
    starts = [] of String
    if exe = Process.executable_path
      starts << File.dirname(exe)
    end
    starts << Dir.current
    starts.uniq.each do |start|
      dir = File.expand_path(start)
      loop do
        add_natives(found, dir, base)
        parent = File.dirname(dir)
        break if parent == dir
        dir = parent
      end
    end
    add_natives(found, File.expand_path(SHARD_ROOT), base)
    found << base
  end

  private def self.add_natives(found, dir, base)
    NATIVE_FOLDERS.each do |folder|
      path = File.join(dir, "natives", folder, base)
      found << path if !found.includes?(path) && File.file?(path)
    end
  end

  # :nodoc:
  # The function table, loading the library on the first call.
  def self.api : Flat::Api
    @@lock.synchronize do
      @@api ||= load_library
    end
  end

  private def self.load_library : Flat::Api
    reasons = [] of String
    library_candidates.each do |path|
      result = try_load(path)
      if result.is_a?(Flat::Api)
        @@loaded_path = path
        return result
      end
      reasons << "#{path} (#{result})"
    end
    raise LibraryError.new("cannot load the KeyNub library; tried #{reasons.join(", ")}")
  end

  private def self.try_load(path : String) : Flat::Api | String
    {% if flag?(:win32) %}
      handle = LibKeyNubKernel32.LoadLibraryW(path.to_utf16)
      return "LoadLibrary error #{LibKeyNubKernel32.GetLastError}" if handle.null?
      result = Flat::Api.resolve { |symbol| LibKeyNubKernel32.GetProcAddress(handle, symbol) }
      if result.is_a?(String)
        LibKeyNubKernel32.FreeLibrary(handle)
        return "does not export #{result}"
      end
      result
    {% else %}
      handle = LibC.dlopen(path, LibC::RTLD_NOW | LibC::RTLD_LOCAL)
      if handle.null?
        text = LibC.dlerror
        return text.null? ? "dlopen failed" : String.new(text)
      end
      result = Flat::Api.resolve { |symbol| LibC.dlsym(handle, symbol) }
      if result.is_a?(String)
        LibC.dlclose(handle)
        return "does not export #{result}"
      end
      result
    {% end %}
  end
end

use v6.d;
use NativeCall;
use KeyNub::LicDongle::Flat;

#| Where the native library (keynub_licdongle_flat) comes from: the path the
#| program names, then KEYNUB_LICDONGLE_FLAT_LIBRARY in the environment, then
#| natives/<platform>/ of an SDK clone from the program's folder and the working
#| directory upwards, then the bare file name for the system loader.
unit module KeyNub::LicDongle::Library;

#| The environment variable that names the library file.
our constant ENVIRONMENT-VARIABLE = 'KEYNUB_LICDONGLE_FLAT_LIBRARY';

#| The platform folders under natives/, in the order they are tried.
our constant NATIVE-FOLDERS = <win-x64 win-x86 win-arm64 linux-x64 linux-arm64 osx-x64 osx-arm64>;

sub windows(--> Bool) { $*DISTRO.is-win }

#| The library's file name on this operating system.
our sub basename(--> Str) {
    return 'keynub_licdongle_flat.dll' if windows();
    return 'libkeynub_licdongle_flat.dylib' if $*KERNEL.name.lc eq 'darwin';
    'libkeynub_licdongle_flat.so'
}

#| The paths tried, in order: the chosen path alone when there is one, the
#| environment variable alone when it is set, otherwise every natives/ match
#| followed by the bare file name.
our sub candidates(Str $chosen? --> List) {
    return ($chosen,) if $chosen;
    my $from-environment = %*ENV{ENVIRONMENT-VARIABLE};
    return ($from-environment,) if $from-environment;
    my $base = basename();
    my @starts;
    with $*PROGRAM -> $program {
        my $file = $program.IO;
        @starts.push: $file.absolute.IO.parent if $file.f;
    }
    @starts.push: $*CWD;
    my @found;
    for @starts.map(*.absolute).unique -> $start {
        my $dir = $start.IO;
        loop {
            for NATIVE-FOLDERS -> $folder {
                my $path = $dir.add('natives').add($folder).add($base).absolute;
                @found.push: $path if $path.IO.f && $path ne @found.any;
            }
            my $parent = $dir.parent;
            last if $parent.absolute eq $dir.absolute;
            $dir = $parent;
        }
    }
    @found.push: $base;
    @found.List
}

# The operating system's loader, to try a candidate before the native subs use it.
sub LoadLibraryW(Str is encoded('utf16') --> Pointer) is native('kernel32') { * }
sub GetProcAddress(Pointer, Str is encoded('ascii') --> Pointer) is native('kernel32') { * }
sub FreeLibrary(Pointer --> int32) is native('kernel32') { * }
sub GetLastError(--> uint32) is native('kernel32') { * }

sub dlopen(Str, int32 --> Pointer) is native { * }
sub dlsym(Pointer, Str --> Pointer) is native { * }
sub dlclose(Pointer --> int32) is native { * }
sub dlerror(--> Str) is native { * }

#| Loads the library at $path and resolves every symbol of the flat API. The
#| empty string when that worked, otherwise the reason it did not.
our sub try-load(Str:D $path --> Str) {
    my constant RTLD_NOW = 2;
    if windows() {
        my $handle = LoadLibraryW($path);
        return "LoadLibrary error {GetLastError()}" unless $handle;
        for KeyNub::LicDongle::Flat::SYMBOLS -> $symbol {
            next if GetProcAddress($handle, $symbol);
            FreeLibrary($handle);
            return "does not export $symbol";
        }
        return '';
    }
    my $handle = dlopen($path, RTLD_NOW);
    return dlerror() // 'dlopen failed' unless $handle;
    for KeyNub::LicDongle::Flat::SYMBOLS -> $symbol {
        next if dlsym($handle, $symbol);
        dlclose($handle);
        return "does not export $symbol";
    }
    ''
}

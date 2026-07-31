#if NETSTANDARD2_0
using System;
using System.IO;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace System.Runtime.CompilerServices
{
    // Polyfill: the compiler recognizes this attribute by full name; netstandard2.0's BCL lacks it.
    [AttributeUsage(AttributeTargets.Method, Inherited = false)]
    internal sealed class ModuleInitializerAttribute : Attribute
    {
    }
}

namespace KeyNub.LicenseDongle.Interop
{
    // On .NET Framework (netstandard2.0 consumers), the host does not resolve the NuGet
    // runtimes/<rid>/native/ tree, so pre-load the process-matching native from the app's
    // runtimes folder (copied there by the package's MSBuild targets). SDK-style .NET (net8.0+)
    // handles this itself and never compiles this file. Fails soft: if nothing is found, the
    // ordinary DllImport probing (app directory, PATH) still applies.
    internal static class NativeLoader
    {
        // A module initializer is the correct tool here: the native must be pre-loaded before the
        // first DllImport binds, transparently to the consumer. This is the "advanced scenario"
        // CA2255 exempts.
#pragma warning disable CA2255
        [ModuleInitializer]
        internal static void Init()
#pragma warning restore CA2255
        {
            if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            {
                return; // .NET Framework native path is Windows-only
            }

            string? rid = RuntimeInformation.ProcessArchitecture switch
            {
                Architecture.X86 => "win-x86",
                Architecture.X64 => "win-x64",
                Architecture.Arm64 => "win-arm64",
                _ => null,
            };
            if (rid == null)
            {
                return;
            }

            string baseDir = AppContext.BaseDirectory ?? string.Empty;
            string path = Path.Combine(baseDir, "runtimes", rid, "native", "keynub_licdongle.dll");
            if (File.Exists(path))
            {
                // Pre-loads the module; the later DllImport("keynub_licdongle") binds to it by name.
                LoadLibrary(path);
            }
        }

        [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr LoadLibrary(string lpFileName);
    }
}
#endif

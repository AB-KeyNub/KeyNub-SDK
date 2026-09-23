using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace KeyNub.LicenseDongle.StandInTests
{
    /// <summary>
    /// Compiles the C ABI stand-in (<c>bindings/julia/test/stub/licd_stub.c</c>, one imaginary
    /// dongle held in memory) into a shared library in the temp directory, with the first C
    /// compiler found of cc, gcc, clang, zig cc and cl, and maps the binding's
    /// <c>keynub_licdongle</c> imports onto it. <c>KEYNUB_SDK_ROOT</c> names the SDK sources when
    /// the tests do not run inside a clone.
    /// </summary>
    internal static class StandIn
    {
        private static readonly Lazy<string> Built = new Lazy<string>(Build);

        /// <summary>The compiled stand-in; compiles it on first use.</summary>
        internal static string Library => Built.Value;

        [ModuleInitializer]
        internal static void Register()
        {
            NativeLibrary.SetDllImportResolver(typeof(LicenseDongleContext).Assembly, Resolve);
        }

        private static IntPtr Resolve(string libraryName, Assembly assembly, DllImportSearchPath? searchPath)
        {
            return libraryName == "keynub_licdongle" ? NativeLibrary.Load(Library) : IntPtr.Zero;
        }

        private static string Build()
        {
            string root = SdkRoot();
            bool windows = OperatingSystem.IsWindows();
            string dir = Path.Combine(Path.GetTempPath(), "keynub-standin-dotnet");
            Directory.CreateDirectory(dir);
            // Not the library's own name: macOS dyld searches DYLD_LIBRARY_PATH by leaf name.
            string output = Path.Combine(dir, windows ? "keynub_licdongle_standin.dll"
                : OperatingSystem.IsMacOS() ? "libkeynub_licdongle_standin.dylib" : "libkeynub_licdongle_standin.so");
            string include = File.Exists(Path.Combine(root, "core", "include", "licdongle.h"))
                ? Path.Combine(root, "core", "include") : Path.Combine(root, "include");
            string source = Path.Combine(root, "bindings", "julia", "test", "stub", "licd_stub.c");

            var gccArgs = new List<string> { "-shared", "-O1", "-DLICD_BUILD_SHARED", "-I" + include, "-o", output, source };
            if (!windows)
            {
                gccArgs.Add("-fPIC");
            }
            var clArgs = new List<string> { "/nologo", "/LD", "/O1", "/DLICD_BUILD_SHARED", "/I" + include, "/Fe:" + output, source };
            var zigArgs = new List<string> { "cc" };
            zigArgs.AddRange(gccArgs);

            var commands = new List<(string, List<string>)>
            {
                ("cc", gccArgs), ("gcc", gccArgs), ("clang", gccArgs), ("zig", zigArgs), ("cl", clArgs),
            };
            foreach ((string program, List<string> args) in commands)
            {
                if (Run(program, args, dir) && File.Exists(output))
                {
                    return output;
                }
            }
            throw new InvalidOperationException(
                "the C ABI stand-in could not be compiled: no C compiler (cc, gcc, clang, zig cc, cl) on the path");
        }

        private static bool Run(string program, List<string> args, string workingDirectory)
        {
            var info = new ProcessStartInfo(program)
            {
                WorkingDirectory = workingDirectory,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            foreach (string arg in args)
            {
                info.ArgumentList.Add(arg);
            }
            try
            {
                using Process process = Process.Start(info)!;
                _ = process.StandardOutput.ReadToEndAsync();
                _ = process.StandardError.ReadToEnd();
                process.WaitForExit();
                return process.ExitCode == 0;
            }
            catch (Win32Exception)
            {
                return false; // not on the path
            }
        }

        private static string SdkRoot()
        {
            string? given = Environment.GetEnvironmentVariable("KEYNUB_SDK_ROOT");
            if (!string.IsNullOrEmpty(given))
            {
                return given;
            }
            for (string? dir = Directory.GetCurrentDirectory(); dir != null; dir = Path.GetDirectoryName(dir))
            {
                if (File.Exists(Path.Combine(dir, "bindings", "flat", "licd_flat.c")))
                {
                    return dir;
                }
            }
            throw new InvalidOperationException(
                "the SDK sources were not found above the working directory; set KEYNUB_SDK_ROOT");
        }
    }
}

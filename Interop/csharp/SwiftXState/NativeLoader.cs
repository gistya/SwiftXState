using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace SwiftXStateWinBridgeInterop;

/// <summary>
/// Resolves the native bridge library across platforms so the package works from a single
/// `runtimes/&lt;rid&gt;/native` layout. The generated P/Invoke uses the Windows name
/// (SwiftXStateWinBridge.dll); on macOS/Linux the file is lib-prefixed (.dylib/.so), and the C
/// runtime `free` lives in libSystem/libc rather than ucrtbase. A module initializer registers the
/// resolver automatically — consumers don't have to call anything.
/// </summary>
internal static class NativeLoader
{
    [ModuleInitializer]
    internal static void Init() =>
        NativeLibrary.SetDllImportResolver(typeof(NativeLoader).Assembly, Resolve);

    private static IntPtr Resolve(string libraryName, Assembly assembly, DllImportSearchPath? searchPath)
    {
        if (libraryName == "ucrtbase.dll")   // where free() lives
        {
            if (OperatingSystem.IsWindows()) return Load("ucrtbase.dll", assembly, searchPath);
            if (OperatingSystem.IsMacOS()) return Load("/usr/lib/libSystem.B.dylib", assembly, searchPath);
            return Load("libc.so.6", assembly, searchPath);
        }

        if (libraryName == "SwiftXStateWinBridge.dll")
        {
            // Locate the library deployed under runtimes/<rid>/native (the file name is plain on
            // Windows and lib-prefixed elsewhere). The default search path is the only source — the
            // shipping resolver deliberately has no environment-variable override, so the native load
            // can't be redirected by anything that can set the process environment.
            string[] names = OperatingSystem.IsWindows()
                ? new[] { "SwiftXStateWinBridge.dll", "SwiftXStateWinBridge" }
                : OperatingSystem.IsMacOS()
                    ? new[] { "SwiftXStateWinBridge", "libSwiftXStateWinBridge.dylib" }
                    : new[] { "SwiftXStateWinBridge", "libSwiftXStateWinBridge.so" };

            foreach (var name in names)
                if (NativeLibrary.TryLoad(name, assembly, searchPath, out var h))
                    return h;
        }

        return IntPtr.Zero;
    }

    private static IntPtr Load(string name, Assembly assembly, DllImportSearchPath? searchPath) =>
        NativeLibrary.TryLoad(name, assembly, searchPath, out var h) ? h : IntPtr.Zero;
}

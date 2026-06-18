# Windows Setup

Here are the instructions to build SwiftXState from source on Windows. 

## Prerequisites

In Windows Settings, enable Developer Mode. 

## Install the Swift Toolchain (Compiler, Dependencies, etc.)

- Download from here: https://www.swift.org/install/windows/

## Download/Pull the sourcecode of the SwiftXState git repo, or pull the repo

- Easiest way is to install git for Windows and then pull

## Build

- cd into the SwiftXState dir in Powershell and build:

**1. Build:**

```powershell
$env:SWIFTXWIN = "1"
swift build -c release --product SwiftXStateWinBridge --show-bin-path
```

That prints the output directory — typically one of:

```
.build\x86_64-unknown-windows-msvc\release\SwiftXStateWinBridge.dll
.build\release\SwiftXStateWinBridge.dll        (older/flat layout)
.build\debug\SwiftXStateWinBridge.dll          (if you didn't pass -c release)
```

Or just search:

```powershell
Get-ChildItem -Recurse -Filter SwiftXStateWinBridge.dll .build
```

**2. Verify the exports are actually in the DLL:**

cd into the location of the built dll. 

From a Visual Studio "Developer Command Prompt":
```
dumpbin /exports SwiftXStateWinBridge.dll
````

Or from powershell: 

```
llvm-objdump -p SwiftXStateWinBridge.dll
```

You want to see `ReactorCreate`, `AddNumbers`, `ReactorSend`, etc. (plain names — x64 cdecl isn't decorated). If they're present, you're good: point C# at the DLL (or drop it next to the app / in `runtimes\win-x64\native\`) and it should work exactly like the macOS run.

**3. NuGet**

If you're getting SwiftXState via NuGet, please note that it will ask to install:

- appx. 16 MB of official Swift .dlls (listed below)
- ask to install official Microsoft C++ and C runtimes (if you don't have them already)
- require you to have Windows KERNEL32.dll present (don't delete this! :D)

Note: Swift's runtime is 12.7% of the size of the Java Runtime (JRE), and you won't get any constant notices about updating it. 

- swift_Concurrency.dll     // official swift features (concurrency)
- swiftDispatch.dll         // official swift features (concurrency)
- BlocksRuntime.dll         // official swift features (closures)
- swift_Core.dll            // official swift core
- Foundation.dll            // official swift functionality
- FoundationEssentials.dll  // official swift functionality
- swiftWinSDK.dll           // official swift windows sdk
- swiftCRT.dll              // official swift C runtime

(Total: 15.9 MB of dependencies)

System-level dependencies:

- KERNEL32.dll                       // windows kernel
- VCRUNTIME140.dll                   // Microsoft Visual C++ redistributable
- api-ms-win-crt-string-l1-1-0.dll   // Microsoft Universal C Runtime (UCRT) library
- api-ms-win-crt-runtime-l1-1-0.dll  // Microsoft Universal C Runtime (UCRT) library
- api-ms-win-crt-heap-l1-1-0.dll     // Microsoft Universal C Runtime (UCRT) library
- api-ms-win-crt-math-l1-1-0.dll     // Microsoft Universal C Runtime (UCRT) library

**4. Local Testing*

If you want to run the SwiftXState tests on Windows:

```
# Run core tests only
swift test --filter SwiftXStateTests
```

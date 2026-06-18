# macOS Setup Guide

## 1. Setup your developer environment

- Install XCode from https://developer.apple.com (if you want to build the sample apps)
- Install Swift from https://www.swift.org/install/macos/ (if you just want to build the core libraries)

## 2. Build the package

### If you have XCode:

- In terminal, if you have Xcode, cd to the SwiftXState repo and simply:

```
swift build
```

Or open one of the sample apps and build it, which will build all the SwiftXState libaries used by that sample app. 

Note that each sample app has a README.md in its own directory that you should check out before building. 

### If you don't have XCode:

The SwiftXState libraries that use SwiftUI require XCode. To build the stuff that doesn't need XCode:

```
swift build \
--product SwiftXState \
--product SwiftXStateInspectorCore \
--product SwiftXStateInspect \
--product SwiftXStateInspectURLSession \
--product SwiftXStateSwiftData
```

## 3. Build an app with SwiftXState

1. Add SwiftXState as a package dependency for your app or library project in XCode.
2. Read our docs and have fun implementing state machine logic in your app :D
3. Post any questions or issues on our Github Issues or Githb Discussions.
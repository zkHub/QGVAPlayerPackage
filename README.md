# QGVAPlayer

Tencent VAP iOS player packaged for Swift Package Manager.

## Requirements

- iOS 12.0+
- Xcode 15+

## Installation

Add this repository as a Swift Package dependency and link the `QGVAPlayer` product.

## Usage

Objective-C:

```objc
#import <QGVAPlayer/QGVAPlayer.h>
```

Swift:

```swift
import QGVAPlayer
```

Create a `QGVAPWrapView` or use the `UIView+VAP` category APIs to play VAP MP4 files from the host app bundle or local file paths.

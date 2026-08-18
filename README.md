# QGVAPlayer

[Tencent VAP](https://github.com/Tencent/vap) iOS player packaged as a standalone Swift Package.

The package contains the Objective-C player sources and Metal shader resource. Video files belong to the host app and are not bundled with the library.

## Requirements

- iOS 12.0+
- Xcode 15+
- Swift 5.9+

## Installation

In Xcode, choose **File > Add Package Dependencies**, enter:

```text
https://github.com/zkHub/QGVAPlayerPackage.git
```

Select a released version and add the `QGVAPlayer` product to your app target.

Or add it to `Package.swift`:

```swift
dependencies: [
    .package(
        url: "https://github.com/zkHub/QGVAPlayerPackage.git",
        from: "1.0.0"
    )
]
```

## Usage

Import the module from Swift:

```swift
import QGVAPlayer
```

Create a player view, configure it before playback, and pass a local VAP MP4 path:

```swift
final class PlayerDelegate: NSObject, VAPWrapViewDelegate {
    func vapWrap_viewDidFailPlayMP4(_ error: Error) {
        print("VAP playback failed: \(error)")
    }
}

let delegate = PlayerDelegate()
let playerView = QGVAPWrapView()
playerView.autoDestoryAfterFinish = false
playerView.setMute(false)
playerView.playHWDMP4(
    videoURL.path,
    repeatCount: 0,
    delegate: delegate
)

// Stop playback before releasing or removing a reusable view.
playerView.stopHWDMP4()
```

Keep the delegate alive for the duration of playback. Delegate callbacks may be delivered from a background thread; dispatch UI updates to the main queue.

For SwiftUI, wrap `QGVAPWrapView` with `UIViewRepresentable`. A complete example is available in [`Examples/QGVAPlayerDemo`](Examples/QGVAPlayerDemo).

Objective-C clients can import the umbrella header:

```objc
#import <QGVAPlayer/QGVAPlayer.h>
```

The `UIView+VAP` category APIs are also exported for clients that prefer to attach playback directly to an existing view.

## Dynamic VAP resources

The player intentionally does not include a network image loader. Implement the delegate resource callbacks when a VAP file contains replaceable image or text tags:

- `vapWrapview_contentForVapTag(_:resource:)`
- `vapWrapView_loadVapImage(withURL:context:completion:)`

## Validation

Simulator builds validate package integration and can preview VAP playback (VideoToolbox software decode + Metal). Prefer Apple Silicon and H.264 assets for simulator preview; HEVC may still fail on Intel simulators. Performance and visual fidelity should be verified on a physical iOS device.

## License

QGVAPlayer is available under the MIT License. See [`LICENSE`](LICENSE). The original VAP source copyright belongs to Tencent.

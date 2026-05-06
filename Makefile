# ActiveSpace — current Space indicator with focus restore.
#
# Release pipeline delegated to the shared `release.mk` from
# PerpetualBeta/jorvik-release. Xcode project (with embedded
# MouseCatcher helper handled internally by the scheme), embedded
# Sparkle, dual-ship (.zip + .pkg).

BUNDLE_NAME      := ActiveSpace
BUNDLE_TYPE      := app
PRODUCT_NAME     := ActiveSpace.app
BUNDLE_ID        := cc.jorviksoftware.ActiveSpace
BUILD_SYSTEM     := xcode

XCODE_PROJECT    := ActiveSpace.xcodeproj
XCODE_SCHEME     := ActiveSpace

PACKAGE_TYPE     := zip
ALSO_SHIP_PKG    := true
EMBEDDED_FRAMEWORKS := Sparkle
ENTITLEMENTS     := ActiveSpace/ActiveSpace.entitlements

include ../jorvik-release/release.mk

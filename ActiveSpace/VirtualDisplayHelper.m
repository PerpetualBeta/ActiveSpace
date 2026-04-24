#import "VirtualDisplayHelper.h"
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

extern void ActiveSpaceLogC(const char *msg);

static void ASLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    ActiveSpaceLogC([msg UTF8String]);
}

/// Dump all instance methods and properties of a class (for private API discovery).
static void dumpClass(Class cls, NSString *label) {
    if (!cls) { ASLog(@"dumpClass: %@ is nil", label); return; }

    ASLog(@"=== %@ instance methods ===", label);
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);
    for (unsigned int i = 0; i < methodCount; i++) {
        SEL sel = method_getName(methods[i]);
        const char *types = method_getTypeEncoding(methods[i]);
        ASLog(@"  %@ — %s", NSStringFromSelector(sel), types ?: "(no encoding)");
    }
    free(methods);

    ASLog(@"=== %@ properties ===", label);
    unsigned int propCount = 0;
    objc_property_t *props = class_copyPropertyList(cls, &propCount);
    for (unsigned int i = 0; i < propCount; i++) {
        const char *name = property_getName(props[i]);
        const char *attrs = property_getAttributes(props[i]);
        ASLog(@"  %s — %s", name, attrs ?: "(no attrs)");
    }
    free(props);
}

@implementation VirtualDisplayHelper

static id _virtualDisplay = nil;
static NSString *_virtualDisplayUUID = nil;

+ (NSString *)displayUUIDString {
    // Lazily retry UUID lookup if it wasn't available at creation time.
    if (_virtualDisplay && !_virtualDisplayUUID) {
        NSNumber *displayID = [_virtualDisplay valueForKey:@"displayID"];
        CGDirectDisplayID cgID = (CGDirectDisplayID)displayID.unsignedIntValue;
        CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(cgID);
        if (uuid) {
            CFStringRef uuidStr = CFUUIDCreateString(NULL, uuid);
            if (uuidStr) {
                _virtualDisplayUUID = (__bridge_transfer NSString *)uuidStr;
            }
            CFRelease(uuid);
        }
    }
    return _virtualDisplayUUID;
}

+ (BOOL)isCreated {
    return _virtualDisplay != nil;
}

+ (NSObject *)create {
    ASLog(@"VirtualDisplayHelper.create entered");
    if (_virtualDisplay) {
        ASLog(@"Virtual display already exists, reusing");
        return _virtualDisplay;
    }

    Class CGVirtualDisplayMode = NSClassFromString(@"CGVirtualDisplayMode");
    Class CGVirtualDisplayDescriptor = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class CGVirtualDisplay = NSClassFromString(@"CGVirtualDisplay");

    ASLog(@"classes — Mode=%@ Descriptor=%@ Display=%@",
          CGVirtualDisplayMode, CGVirtualDisplayDescriptor, CGVirtualDisplay);

    if (!CGVirtualDisplay || !CGVirtualDisplayDescriptor || !CGVirtualDisplayMode) {
        ASLog(@"One or more CGVirtualDisplay classes not available");
        return nil;
    }

    // Full introspection dump — looking for properties/methods that could
    // mark this display as headless/internal to avoid coordinate corruption.
    dumpClass(CGVirtualDisplayMode, @"CGVirtualDisplayMode");
    dumpClass(CGVirtualDisplayDescriptor, @"CGVirtualDisplayDescriptor");
    dumpClass(CGVirtualDisplay, @"CGVirtualDisplay");
    dumpClass(NSClassFromString(@"CGVirtualDisplaySettings"), @"CGVirtualDisplaySettings");

    // Create mode: 640x480 @ 60Hz. This is large enough that macOS treats it as
    // a real display (and so forces UUID-based display identifiers, fixing the
    // single-monitor "Main" identifier issue that breaks Dock gesture routing).
    // Smaller sizes (e.g. 1x1) get ignored by macOS and don't trigger the fix.
    SEL modeSel = NSSelectorFromString(@"initWithWidth:height:refreshRate:");
    NSMethodSignature *modeSig = [CGVirtualDisplayMode instanceMethodSignatureForSelector:modeSel];
    if (!modeSig) {
        ASLog(@"CGVirtualDisplayMode has no initWithWidth:height:refreshRate:");
        return nil;
    }
    NSInvocation *modeInv = [NSInvocation invocationWithMethodSignature:modeSig];
    modeInv.selector = modeSel;
    unsigned int w = 640, h = 480;
    double rate = 60.0;
    [modeInv setArgument:&w atIndex:2];
    [modeInv setArgument:&h atIndex:3];
    [modeInv setArgument:&rate atIndex:4];
    id modeObj = [CGVirtualDisplayMode alloc];
    [modeInv invokeWithTarget:modeObj];
    __unsafe_unretained id mode;
    [modeInv getReturnValue:&mode];
    ASLog(@"mode creation result — %@", mode);

    if (!mode) {
        ASLog(@"Failed to create CGVirtualDisplayMode");
        return nil;
    }

    // Create descriptor
    id desc = [[CGVirtualDisplayDescriptor alloc] init];
    [desc setValue:@"ActiveSpace Virtual Display" forKey:@"name"];
    [desc setValue:@(0xACE5) forKey:@"vendorID"];
    [desc setValue:@(0x0001) forKey:@"productID"];
    [desc setValue:@(0x0001) forKey:@"serialNum"];
    [desc setValue:@(640) forKey:@"maxPixelsWide"];
    [desc setValue:@(480) forKey:@"maxPixelsHigh"];
    [desc setValue:[NSValue valueWithSize:NSMakeSize(169, 127)] forKey:@"sizeInMillimeters"];
    [desc setValue:dispatch_get_main_queue() forKey:@"queue"];

    // Create virtual display
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id display = [[CGVirtualDisplay alloc] performSelector:NSSelectorFromString(@"initWithDescriptor:") withObject:desc];
#pragma clang diagnostic pop

    if (!display) {
        ASLog(@"Failed to create virtual display");
        return nil;
    }

    _virtualDisplay = display;
    NSNumber *displayID = [display valueForKey:@"displayID"];
    CGDirectDisplayID cgID = (CGDirectDisplayID)displayID.unsignedIntValue;
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(cgID);
    if (uuid) {
        CFStringRef uuidStr = CFUUIDCreateString(NULL, uuid);
        if (uuidStr) {
            _virtualDisplayUUID = (__bridge_transfer NSString *)uuidStr;
        }
        CFRelease(uuid);
    }
    ASLog(@"Virtual display created (ID %u, UUID %@)", cgID, _virtualDisplayUUID ?: @"unknown");

    // Apply the mode via CGVirtualDisplaySettings.applySettings: — the real
    // selector on macOS 26, discovered by introspection. Without this step
    // the display object exists but is never "online" and NSScreen.screens
    // never picks it up, so isSingleDisplay() keeps returning true and the
    // real display's identifier remains "Main".
    Class CGVirtualDisplaySettings = NSClassFromString(@"CGVirtualDisplaySettings");
    if (CGVirtualDisplaySettings && mode) {
        id settings = [[CGVirtualDisplaySettings alloc] init];

        // setModes: is a proper setter method on Settings.
        SEL setModesSel = NSSelectorFromString(@"setModes:");
        NSMethodSignature *modesSig = [settings methodSignatureForSelector:setModesSel];
        if (modesSig) {
            NSInvocation *modesInv = [NSInvocation invocationWithMethodSignature:modesSig];
            modesInv.selector = setModesSel;
            modesInv.target = settings;
            NSArray *modeArray = @[mode];
            [modesInv setArgument:&modeArray atIndex:2];
            [modesInv invoke];
            ASLog(@"setModes: invoked with [mode]");
        } else {
            ASLog(@"CGVirtualDisplaySettings has no setModes: — falling back to KVC");
            @try { [settings setValue:@[mode] forKey:@"modes"]; }
            @catch (NSException *e) { ASLog(@"modes KVC failed: %@", e.reason); }
        }

        // applySettings: takes the settings object and returns BOOL.
        SEL applySel = NSSelectorFromString(@"applySettings:");
        NSMethodSignature *applySig = [display methodSignatureForSelector:applySel];
        if (applySig) {
            NSInvocation *applyInv = [NSInvocation invocationWithMethodSignature:applySig];
            applyInv.selector = applySel;
            applyInv.target = display;
            [applyInv setArgument:&settings atIndex:2];
            [applyInv invoke];
            BOOL result = NO;
            if (strcmp(applySig.methodReturnType, @encode(BOOL)) == 0) {
                [applyInv getReturnValue:&result];
            }
            ASLog(@"applySettings: invoked, return=%@", result ? @"YES" : @"NO/void");
        } else {
            ASLog(@"display has no applySettings: selector");
        }
    } else {
        ASLog(@"CGVirtualDisplaySettings class not available — mode not applied");
    }

    // Position the virtual display contiguously adjacent to the right
    // edge of the main display. Previously used a +6000 gap, which macOS
    // silently rejects on larger display arrangements (e.g. 5K displays
    // with 2× scaling produce a 2560-point-wide main; 8560 requested
    // position was too far, macOS auto-snapped the virtual to the LEFT
    // of main at mid-height, and the Dock migrated there).
    //
    // Contiguous-right is the position macOS naturally wants for a
    // secondary display in a single-primary arrangement — it doesn't
    // get repositioned, so the Dock sees no attractive landing spot.
    // This is only invoked when there's exactly one physical display
    // (see VirtualDisplay.reconcile), so right-of-main is always safe.
    CGDirectDisplayID mainDisplay = CGMainDisplayID();
    CGRect mainBounds = CGDisplayBounds(mainDisplay);
    int32_t offX = (int32_t)(mainBounds.origin.x + mainBounds.size.width);
    int32_t offY = (int32_t)(mainBounds.origin.y);

    CGDisplayConfigRef config = NULL;
    CGError err = CGBeginDisplayConfiguration(&config);
    if (err == kCGErrorSuccess && config) {
        CGConfigureDisplayOrigin(config, cgID, offX, offY);
        ASLog(@"CGConfigureDisplayOrigin(virtual=%u, %d, %d) [mainBounds=%@]", cgID, offX, offY, NSStringFromRect(NSRectFromCGRect(mainBounds)));
        CGError complete = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
        ASLog(@"CGCompleteDisplayConfiguration → %d", complete);
    } else {
        ASLog(@"CGBeginDisplayConfiguration failed: %d", err);
    }

    ASLog(@"Post-create NSScreen.screens.count = %lu", (unsigned long)[NSScreen screens].count);

    // Also log where the virtual display actually ended up, so we can spot
    // future macOS auto-repositioning without digging through events.
    CGRect virtualBounds = CGDisplayBounds(cgID);
    ASLog(@"Post-create virtual bounds = %@", NSStringFromRect(NSRectFromCGRect(virtualBounds)));

    return display;
}

+ (void)destroy {
    if (!_virtualDisplay) return;

    ASLog(@"Destroying virtual display");

    // WindowServer caches bezel / shadow-ring layer-tree state for every
    // registered display. Simply dropping our CGVirtualDisplay reference
    // removes the display from NSScreen.screens but doesn't purge that
    // cached state — the residue shows up as faint corner drop-shadows at
    // the virtual's last-known position and persists until the user logs
    // out. Before releasing, force the compositor to (a) move the display's
    // rendering region to an off-screen coordinate and (b) shrink its mode
    // to 1x1, so any leftover geometry ends up at zero-area or in an
    // invisible part of the coordinate space.

    NSNumber *displayIDNum = [_virtualDisplay valueForKey:@"displayID"];
    CGDirectDisplayID cgID = (CGDirectDisplayID)displayIDNum.unsignedIntValue;

    // Step 1 — relocate to an extreme off-screen coordinate.
    CGDisplayConfigRef config = NULL;
    CGError beginErr = CGBeginDisplayConfiguration(&config);
    if (beginErr == kCGErrorSuccess && config) {
        CGConfigureDisplayOrigin(config, cgID, -32768, -32768);
        CGError completeErr = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
        ASLog(@"  destroy step 1: relocating (displayID=%u) to (-32768,-32768) → CGCompleteDisplayConfiguration=%d", cgID, completeErr);
    } else {
        ASLog(@"  destroy step 1: CGBeginDisplayConfiguration failed (%d) — skipping relocate", beginErr);
    }

    // Step 2 — shrink the display's advertised mode to 1x1 so the compositor
    // reduces its rendering region to a null area before we release.
    Class CGVirtualDisplayMode = NSClassFromString(@"CGVirtualDisplayMode");
    Class CGVirtualDisplaySettings = NSClassFromString(@"CGVirtualDisplaySettings");
    if (CGVirtualDisplayMode && CGVirtualDisplaySettings) {
        SEL modeInitSel = NSSelectorFromString(@"initWithWidth:height:refreshRate:");
        NSMethodSignature *modeSig = [CGVirtualDisplayMode instanceMethodSignatureForSelector:modeInitSel];
        id tinyMode = nil;
        if (modeSig) {
            NSInvocation *modeInv = [NSInvocation invocationWithMethodSignature:modeSig];
            modeInv.selector = modeInitSel;
            unsigned int w = 1, h = 1;
            double rate = 60.0;
            [modeInv setArgument:&w atIndex:2];
            [modeInv setArgument:&h atIndex:3];
            [modeInv setArgument:&rate atIndex:4];
            id modeObj = [CGVirtualDisplayMode alloc];
            [modeInv invokeWithTarget:modeObj];
            __unsafe_unretained id result;
            [modeInv getReturnValue:&result];
            tinyMode = result;
        }

        if (tinyMode) {
            id tinySettings = [[CGVirtualDisplaySettings alloc] init];
            SEL setModesSel = NSSelectorFromString(@"setModes:");
            NSMethodSignature *setModesSig = [tinySettings methodSignatureForSelector:setModesSel];
            if (setModesSig) {
                NSInvocation *setModesInv = [NSInvocation invocationWithMethodSignature:setModesSig];
                setModesInv.selector = setModesSel;
                setModesInv.target = tinySettings;
                NSArray *modeArray = @[tinyMode];
                [setModesInv setArgument:&modeArray atIndex:2];
                [setModesInv invoke];
            } else {
                @try { [tinySettings setValue:@[tinyMode] forKey:@"modes"]; }
                @catch (NSException *e) { /* best-effort */ }
            }

            SEL applySel = NSSelectorFromString(@"applySettings:");
            NSMethodSignature *applySig = [_virtualDisplay methodSignatureForSelector:applySel];
            if (applySig) {
                NSInvocation *applyInv = [NSInvocation invocationWithMethodSignature:applySig];
                applyInv.selector = applySel;
                applyInv.target = _virtualDisplay;
                [applyInv setArgument:&tinySettings atIndex:2];
                [applyInv invoke];
                BOOL applied = NO;
                if (strcmp(applySig.methodReturnType, @encode(BOOL)) == 0) {
                    [applyInv getReturnValue:&applied];
                }
                ASLog(@"  destroy step 2: shrinking to 1x1 mode → applySettings=%@", applied ? @"YES" : @"NO/void");
            } else {
                ASLog(@"  destroy step 2: virtual display has no applySettings: — skipping shrink");
            }
        } else {
            ASLog(@"  destroy step 2: failed to construct 1x1 CGVirtualDisplayMode — skipping shrink");
        }
    } else {
        ASLog(@"  destroy step 2: CGVirtualDisplayMode/Settings class unavailable — skipping shrink");
    }

    // Step 3 — release. ARC deallocates the CGVirtualDisplay object.
    ASLog(@"  destroy step 3: releasing reference");
    _virtualDisplay = nil;
    _virtualDisplayUUID = nil;
}

@end

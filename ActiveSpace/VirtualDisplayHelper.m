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

    // Position the virtual display far to the right of the main display
    // so the Dock doesn't migrate to it. The display must NOT be mirrored
    // (mirrored displays count as one screen and the Dock treats them as
    // single-display, defeating the UUID identifier mechanism).
    CGDirectDisplayID mainDisplay = CGMainDisplayID();
    CGRect mainBounds = CGDisplayBounds(mainDisplay);
    int32_t offX = (int32_t)(mainBounds.origin.x + mainBounds.size.width + 6000);
    int32_t offY = 0;

    CGDisplayConfigRef config = NULL;
    CGError err = CGBeginDisplayConfiguration(&config);
    if (err == kCGErrorSuccess && config) {
        CGConfigureDisplayOrigin(config, cgID, offX, offY);
        ASLog(@"CGConfigureDisplayOrigin(virtual=%u, %d, %d)", cgID, offX, offY);
        CGError complete = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
        ASLog(@"CGCompleteDisplayConfiguration → %d", complete);
    } else {
        ASLog(@"CGBeginDisplayConfiguration failed: %d", err);
    }

    ASLog(@"Post-create NSScreen.screens.count = %lu", (unsigned long)[NSScreen screens].count);

    return display;
}

+ (void)destroy {
    if (_virtualDisplay) {
        ASLog(@"Destroying virtual display");
        _virtualDisplay = nil;
        _virtualDisplayUUID = nil;
    }
}

@end

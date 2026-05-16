// VirtualDisplayHost — bundled helper that owns ActiveSpace's CGVirtualDisplay.
//
// Why a separate process: ActiveSpace's in-process create path collided
// with WindowServer's saved-state replay (vendor 0xACE5 has historical
// mirror-master entanglement; initial CGCompleteDisplayConfiguration was
// rejected with kCGErrorIllegalArgument, the virtual fell back to right-
// of-main, and downstream reposition didn't get the clamp treatment so
// NSScreen.screens never registered it). This process uses unique vendor
// IDs that the saved-state index has never seen, so the initial config
// is accepted on the first try and the (-32768,-32768) request gets
// clamped to (-width,-height) — bounds fully off-screen, NSScreen.screens
// count flips to 2, macOS-16's "Main"-identifier gesture-routing bug
// stays disarmed.
//
// Lifecycle is parent-tied: ActiveSpace launches us via Process() and
// SIGTERMs us in applicationWillTerminate. As a belt-and-braces against
// ActiveSpace crashing hard before SIGTERM, we poll getppid() every two
// seconds and exit cleanly when it changes (parent died, we got
// reparented to launchd / pid 1).
//
// Conventions:
//
//   - Vendor 0x4A56 (ASCII "JV") — Jorvik signature.
//   - Product 0x0001 / Serial 0x0001.
//   - 800×600 mode — known-working baseline from extensive size-walk
//     experimentation (1×1 triggers macOS's screen-share picker;
//     640×480 is fine but 800 fits the established pattern).
//   - Position (-32768,-32768) — macOS clamps to (-width,-height) on
//     accept, putting maxX=maxY=0 exactly.
//   - Mirror=NULL for self and main — defensive against any future
//     saved-state collision.

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>
#import <signal.h>
#import <unistd.h>

static void log_(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    fprintf(stderr, "[VirtualDisplayHost %d] %s\n", getpid(), msg.UTF8String);
    fflush(stderr);
}

// MARK: - Private API dance (NSInvocation-based to dodge ARC's init-family rules)

static id make_mode(unsigned int w, unsigned int h) {
    Class CGVirtualDisplayMode = NSClassFromString(@"CGVirtualDisplayMode");
    if (!CGVirtualDisplayMode) return nil;
    SEL sel = NSSelectorFromString(@"initWithWidth:height:refreshRate:");
    NSMethodSignature *sig = [CGVirtualDisplayMode instanceMethodSignatureForSelector:sel];
    if (!sig) return nil;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.selector = sel;
    double rate = 60.0;
    [inv setArgument:&w atIndex:2];
    [inv setArgument:&h atIndex:3];
    [inv setArgument:&rate atIndex:4];
    id obj = [CGVirtualDisplayMode alloc];
    [inv invokeWithTarget:obj];
    __unsafe_unretained id result;
    [inv getReturnValue:&result];
    return result;
}

// NOTE: do NOT factor the alloc+invoke-init pattern out of main into a
// helper that returns `id`. The original VirtualDisplayHelper.m worked
// because the alloc result was stored in a __strong static (binding a
// retain) before the local going out of scope could trigger ARC's
// scope-exit release. Putting that dance in a function and returning
// the init result via __unsafe_unretained crashes in objc_release on
// scope exit — the object's retain count is consumed by init but ARC
// tracking lags, and the dangling pointer comes back to bite us when
// the caller's strong reference tries to use it. The CGVirtualDisplay
// creation is inlined in main() for that reason; everything else can
// stay factored.

static void apply_settings(id display, id mode) {
    Class CGVirtualDisplaySettings = NSClassFromString(@"CGVirtualDisplaySettings");
    if (!CGVirtualDisplaySettings) return;
    id settings = [[CGVirtualDisplaySettings alloc] init];
    [settings setValue:@[mode] forKey:@"modes"];

    SEL applySel = NSSelectorFromString(@"applySettings:");
    NSMethodSignature *sig = [display methodSignatureForSelector:applySel];
    if (!sig) return;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.selector = applySel;
    inv.target = display;
    [inv setArgument:&settings atIndex:2];
    [inv invoke];
    BOOL ok = NO;
    if (strcmp(sig.methodReturnType, @encode(BOOL)) == 0) {
        [inv getReturnValue:&ok];
    }
    log_(@"applySettings: %@", ok ? @"YES" : @"NO/void");
}

// MARK: - Lifecycle

// ARC-strong reference holds the virtual alive for the process lifetime.
// We don't explicitly release it on shutdown — the signal handler just
// `_exit(0)`s, and WindowServer deregisters the virtual when our
// connection drops as the kernel reaps the process. The graceful
// `g_display = nil` chain (ARC release → dealloc → XPC) isn't
// async-signal-safe and bouncing to the main queue via dispatch_async
// from the signal handler doesn't help: signal returns immediately,
// default disposition terminates the process, the dispatched block
// never gets to run. `_exit` is the only correct shutdown move from a
// signal handler — and macOS's process-teardown path does the cleanup
// for us anyway.
static id g_display = nil;

static void signal_handler(int sig) {
    static const char marker[] = "[VirtualDisplayHost] signal received\n";
    write(STDERR_FILENO, marker, sizeof(marker) - 1);
    _exit(0);
}

// Parent-death watcher: getppid() returns 1 once we've been reparented
// to launchd, which happens when ActiveSpace dies without SIGTERMing us
// first (crash, kill -9, etc.). Polled on the main run loop via an
// NSTimer — keeps everything on one queue and out of GCD's hands, which
// matters because the CGVirtualDisplay descriptor's `queue` is set to
// dispatch_get_main_queue() and the prior background-queue timer was
// correlated with a SIGSEGV in objc_release on the main thread once
// the listener spun up.
static void install_parent_watcher(pid_t initial_parent) {
    [NSTimer scheduledTimerWithTimeInterval:2.0
                                    repeats:YES
                                      block:^(NSTimer *t) {
        pid_t current = getppid();
        if (current != initial_parent) {
            log_(@"parent PID changed (%d → %d) — exiting", initial_parent, current);
            _exit(0);
        }
    }];
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        signal(SIGINT, signal_handler);
        signal(SIGTERM, signal_handler);
        signal(SIGHUP, signal_handler);

        pid_t parent = getppid();
        log_(@"starting, parent=%d", parent);

        Class CGVirtualDisplayDescriptor = NSClassFromString(@"CGVirtualDisplayDescriptor");
        if (!CGVirtualDisplayDescriptor) {
            log_(@"CGVirtualDisplayDescriptor unavailable — aborting");
            return 1;
        }

        unsigned int w = 800, h = 600;
        id modeObj = make_mode(w, h);
        if (!modeObj) { log_(@"mode creation failed"); return 1; }

        id desc = [[CGVirtualDisplayDescriptor alloc] init];
        [desc setValue:@"ActiveSpace VirtualDisplayHost" forKey:@"name"];
        // 0x4A56 = "JV" (Jorvik). Unique to this helper — distinct from
        // ActiveSpace's legacy 0xACE5 so the saved-displays plist treats
        // each instance as a fresh device with no replayed history.
        // 0x4A56 = "JV" (Jorvik). Vendor ID is stable for grep-ability;
        // serial = PID so each helper instance is unique. Stable IDs
        // (like the original 0x4A56/1/1) collide with WindowServer's
        // saved registry when a prior helper crashed and left a virtual
        // behind: CGVirtualDisplay init fails because the IDs are
        // "taken" by the leaked entry. PID-as-serial sidesteps that
        // entirely — collisions are impossible since PIDs don't repeat
        // for the lifetime of a boot.
        [desc setValue:@(0x4A56) forKey:@"vendorID"];
        [desc setValue:@(0x0001) forKey:@"productID"];
        [desc setValue:@((unsigned int)getpid()) forKey:@"serialNum"];
        [desc setValue:@(w) forKey:@"maxPixelsWide"];
        [desc setValue:@(h) forKey:@"maxPixelsHigh"];
        [desc setValue:[NSValue valueWithSize:NSMakeSize(76.2, 57.1)] forKey:@"sizeInMillimeters"];
        [desc setValue:dispatch_get_main_queue() forKey:@"queue"];

        // Inline alloc + invoke-init dance. See make_display note above.
        Class CGVirtualDisplayCls = NSClassFromString(@"CGVirtualDisplay");
        if (!CGVirtualDisplayCls) {
            log_(@"CGVirtualDisplay class unavailable — aborting");
            return 1;
        }
        SEL initSel = NSSelectorFromString(@"initWithDescriptor:");
        NSMethodSignature *initSig = [CGVirtualDisplayCls instanceMethodSignatureForSelector:initSel];
        if (!initSig) {
            log_(@"CGVirtualDisplay has no initWithDescriptor: — aborting");
            return 1;
        }
        NSInvocation *initInv = [NSInvocation invocationWithMethodSignature:initSig];
        initInv.selector = initSel;
        [initInv setArgument:&desc atIndex:2];
        id display = [CGVirtualDisplayCls alloc];
        [initInv invokeWithTarget:display];
        __unsafe_unretained id initResult;
        [initInv getReturnValue:&initResult];
        if (!initResult) {
            log_(@"CGVirtualDisplay init failed");
            return 1;
        }
        g_display = display;   // Strong assignment binds the alloc result.

        NSNumber *displayIDNum = [g_display valueForKey:@"displayID"];
        CGDirectDisplayID cgID = (CGDirectDisplayID)displayIDNum.unsignedIntValue;
        log_(@"created virtual displayID=%u", cgID);

        apply_settings(g_display, modeObj);

        // Park off-screen. macOS clamps the extreme negative origin to
        // (-width, -height) on accept, making maxX=maxY=0 — fully
        // non-positive quadrant, unreachable by cursor or windows.
        CGDirectDisplayID mainID = CGMainDisplayID();
        CGDisplayConfigRef config = NULL;
        if (CGBeginDisplayConfiguration(&config) == kCGErrorSuccess && config) {
            CGConfigureDisplayOrigin(config, cgID, -32768, -32768);
            CGConfigureDisplayMirrorOfDisplay(config, cgID, kCGNullDirectDisplay);
            if (mainID != cgID) {
                CGConfigureDisplayMirrorOfDisplay(config, mainID, kCGNullDirectDisplay);
            }
            CGError err = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
            log_(@"CGComplete=%d (origin=-32768,-32768 + mirror=NULL)", err);
        }

        CGRect b = CGDisplayBounds(cgID);
        log_(@"post-create bounds=(%g,%g,%gx%g) online=%d active=%d NSScreen.count=%lu",
             b.origin.x, b.origin.y, b.size.width, b.size.height,
             CGDisplayIsOnline(cgID), CGDisplayIsActive(cgID),
             (unsigned long)NSScreen.screens.count);

        install_parent_watcher(parent);

        [[NSRunLoop mainRunLoop] run];
        return 0;
    }
}

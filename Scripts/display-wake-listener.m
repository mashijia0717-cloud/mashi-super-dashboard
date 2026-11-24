#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <IOKit/IOKitLib.h>
#include "RDDisplayTopology.h"

typedef RDTopology (^RDTopologyProvider)(void);
typedef void (^RDScheduler)(NSTimeInterval, dispatch_block_t);
typedef void (^RDCommandRunner)(NSString *, NSArray<NSString *> *, void (^)(int));
typedef BOOL (^RDOwnedDeadlockProvider)(void);

static BOOL RDSystemLidIsOpen(void) {
    io_service_t root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    if (!root) return NO;
    CFTypeRef value = IORegistryEntryCreateCFProperty(root, CFSTR("AppleClamshellState"), kCFAllocatorDefault, 0);
    IOObjectRelease(root);
    BOOL open = value && CFGetTypeID(value) == CFBooleanGetTypeID() && !CFBooleanGetValue(value);
    if (value) CFRelease(value);
    return open;
}

static NSString *RDPreferredScreenBlankPath(void) {
    NSString *dashboardHelper = @"/Applications/Super Dashboard.app/Contents/MacOS/ScreenBlank";
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:dashboardHelper]) return dashboardHelper;
    return @"/Applications/显示器控制台.app/Contents/MacOS/ScreenBlank";
}

@interface DisplayWakeListener : NSObject
@property BOOL pending;
@property BOOL running;
@property BOOL rerun;
@property BOOL selfTest;
@property NSUInteger generation;
@property BOOL synchronousTesting;
@property BOOL sleeping;
@property BOOL systemSleeping;
@property NSUInteger retryAttempt;
@property CGDirectDisplayID removedExternal;
@property(copy) RDScheduler scheduler;
@property(copy) RDTopologyProvider topologyProvider;
@property(copy) RDCommandRunner commandRunner;
@property(copy) RDOwnedDeadlockProvider ownedDeadlockProvider;
- (instancetype)initWithTopologyProvider:(RDTopologyProvider)provider commandRunner:(RDCommandRunner)runner;
- (void)handleDisplayChange:(CGDirectDisplayID)display flags:(CGDisplayChangeSummaryFlags)flags;
- (void)startAdoptingExisting:(BOOL)adopting;
@end

@implementation DisplayWakeListener {
    RDTopologyGate _topologyGate;
    uint32_t _knownExternals[RD_TOPOLOGY_CAPACITY];
    uint32_t _knownExternalCount;
}

- (void)rememberExternalsFromTopology:(RDTopology)topology {
    if (!topology.valid) return;
    for (uint32_t i = 0; i < topology.physicalCount; i++) {
        RDDisplay row = topology.physical[i];
        if ((row.flags & RD_BUILTIN) || (row.flags & RD_VIRTUAL) || !(row.flags & RD_ONLINE)) continue;
        BOOL exists = NO;
        for (uint32_t k = 0; k < _knownExternalCount; k++) {
            if (_knownExternals[k] == row.id) { exists = YES; break; }
        }
        if (!exists && _knownExternalCount < RD_TOPOLOGY_CAPACITY) {
            _knownExternals[_knownExternalCount++] = row.id;
        }
    }
}

- (BOOL)wasKnownExternal:(CGDirectDisplayID)display {
    for (uint32_t k = 0; k < _knownExternalCount; k++) {
        if (_knownExternals[k] == display) return YES;
    }
    for (uint32_t i = 0; i < _topologyGate.previous.physicalCount; i++) {
        RDDisplay row = _topologyGate.previous.physical[i];
        if (row.id == display && !(row.flags & RD_BUILTIN) && !(row.flags & RD_VIRTUAL)) return YES;
    }
    return NO;
}

- (void)forgetKnownExternal:(CGDirectDisplayID)display {
    uint32_t kept = 0;
    for (uint32_t k = 0; k < _knownExternalCount; k++) {
        if (_knownExternals[k] != display) _knownExternals[kept++] = _knownExternals[k];
    }
    _knownExternalCount = kept;
}

- (BOOL)hasHeadlessOwnedBuiltinDeadlock:(RDTopology)topology {
    if (self.ownedDeadlockProvider) return self.ownedDeadlockProvider();
    if (!RDSystemLidIsOpen()) return NO;
    if (RDUsableExternalCount(&topology) > 0) return NO;
    for (uint32_t i = 0; i < topology.physicalCount; i++) {
        uint32_t flags = topology.physical[i].flags;
        if (!(flags & RD_VIRTUAL) && (flags & RD_ONLINE)) return NO;
    }
    NSString *support = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/DisplayPanel"];
    BOOL hasDisabled = [[NSFileManager defaultManager] fileExistsAtPath:[support stringByAppendingPathComponent:@"disabled-builtin.json"]];
    BOOL hasBlankState = [[NSFileManager defaultManager] fileExistsAtPath:[support stringByAppendingPathComponent:@"screen-sleep-state.json"]];
    return hasDisabled || hasBlankState;
}

- (instancetype)initWithTopologyProvider:(RDTopologyProvider)provider commandRunner:(RDCommandRunner)runner {
    if ((self = [super init])) {
        _topologyProvider = [provider copy];
        _commandRunner = [runner copy];
        RDTopology initial = provider();
        _topologyGate = RDTopologyGateCreate(initial);
        [self rememberExternalsFromTopology:initial];
        BOOL online = NO, awake = NO;
        for (uint32_t i=0;i<initial.physicalCount;i++) {
            uint32_t flags=initial.physical[i].flags;
            if (flags & RD_VIRTUAL) continue;
            online |= (flags & RD_ONLINE) != 0;
            awake |= (flags & (RD_ONLINE|RD_ACTIVE|RD_ASLEEP)) == (RD_ONLINE|RD_ACTIVE);
        }
        _sleeping = initial.valid && online && !awake;
        _systemSleeping = NO;
    }
    return self;
}

- (void)runCommand:(NSString *)path arguments:(NSArray<NSString *> *)arguments completion:(void (^)(int))completion {
    if (self.commandRunner) { self.commandRunner(path, arguments, completion); return; }
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = arguments;
    task.terminationHandler = ^(NSTask *finished) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(finished.terminationStatus); });
    };
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        NSLog(@"display helper failed: %@", error);
        completion(1);
    }
}

- (void)requestCheck {
    if (self.sleeping || self.systemSleeping) return;
    if (self.running) { self.rerun = YES; self.generation++; return; }
    if (self.pending) return; // coalesce without starving recovery during a callback burst
    self.pending = YES;
    NSUInteger generation = ++self.generation;
    dispatch_block_t check = ^{
        if (generation != self.generation || self.sleeping || self.systemSleeping) return;
        self.pending = NO;
        [self checkLayout];
    };
    NSTimeInterval delay = self.retryAttempt ? (self.retryAttempt == 1 ? 0.25 : self.retryAttempt == 2 ? 0.75 : 2) : 0.25;
    if (self.scheduler) self.scheduler(delay, check);
    else if (self.synchronousTesting) check();
    else dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), check);
}

- (void)completeCheck:(int)status generation:(NSUInteger)generation {
    self.running = NO;
    if (self.sleeping || self.systemSleeping) return;
    BOOL changed = self.rerun || generation != self.generation;
    self.rerun = NO;
    if (changed) { self.retryAttempt = 0; [self requestCheck]; return; }
    if (status != 0 && self.retryAttempt < 3) { self.retryAttempt++; [self requestCheck]; }
    else {
        if (status != 0) NSLog(@"display recovery deferred after four attempts; saved state retained");
        else if (self.removedExternal) {
            [self forgetKnownExternal:self.removedExternal];
        }
        self.retryAttempt = 0;
    }
}

- (void)checkLayout {
    if (self.sleeping || self.systemSleeping) return;
    if (self.running) { self.rerun = YES; return; }
    if (self.selfTest) { puts("notification received; layout check scheduled; no display changes"); exit(0); }
    self.running = YES;
    NSUInteger generation = self.generation;
    NSArray *recoveryArguments = self.removedExternal ? @[@"--recover-orphan", @"--observed-removal"] : @[@"--recover-orphan"];
    [self runCommand:RDPreferredScreenBlankPath() arguments:recoveryArguments completion:^(int status) {
        if (status != 0 || self.sleeping || self.systemSleeping || generation != self.generation) { [self completeCheck:status generation:generation]; return; }
        NSArray *arguments = self.removedExternal ? @[@"--observed-removal", [NSString stringWithFormat:@"%u", self.removedExternal]] : @[];
        [self runCommand:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Scripts/cindy-fix-main-display.sh"] arguments:arguments completion:^(int layoutStatus) {
            [self completeCheck:layoutStatus generation:generation];
        }];
    }];
}

- (void)wake:(NSNotification *)notification {
    RDEvent event = !notification || [notification.name isEqual:NSWorkspaceDidWakeNotification] || self.sleeping || self.systemSleeping ? RDEventWake : RDEventScreenWake;
    self.sleeping = NO;
    self.systemSleeping = NO;
    RDTopology current = self.topologyProvider();
    [self rememberExternalsFromTopology:current];
    if (!RDTopologyShouldProcess(&_topologyGate, current, event, 0) && !self.removedExternal && ![self hasHeadlessOwnedBuiltinDeadlock:current]) return;
    self.retryAttempt = 0;
    [self requestCheck];
}

- (void)sleep:(NSNotification *)notification {
    BOOL fullSystemSleep = !notification || [notification.name isEqual:NSWorkspaceWillSleepNotification];
    if (fullSystemSleep) {
        self.systemSleeping = YES;
    }
    // If only screens reported sleep because the sole active external monitor was just unplugged
    // while our disabled-builtin record still keeps the open-lid laptop screen disabled, do NOT
    // cancel the pending recovery check! Otherwise no online screen remains to ever emit ScreensDidWake.
    if (!fullSystemSleep) {
        RDTopology current = self.topologyProvider();
        if (self.removedExternal != 0 && [self hasHeadlessOwnedBuiltinDeadlock:current]) {
            self.sleeping = NO;
            [self requestCheck];
            return;
        }
    }
    self.sleeping = YES; self.generation++; self.pending = NO; self.rerun = NO; self.retryAttempt = 0;
}

- (void)handleDisplayChange:(CGDirectDisplayID)display flags:(CGDisplayChangeSummaryFlags)flags {
    if (!(flags & (kCGDisplayAddFlag | kCGDisplayRemoveFlag | kCGDisplayEnabledFlag | kCGDisplayDisabledFlag)) || (flags & kCGDisplayBeginConfigurationFlag)) return;
    RDTopology current = self.topologyProvider();
    BOOL physicalExternal = [self wasKnownExternal:display];
    if ((flags & kCGDisplayRemoveFlag) && physicalExternal) self.removedExternal = display;
    if (flags & kCGDisplayAddFlag) {
        for (uint32_t i=0;i<current.physicalCount;i++) {
            if (current.physical[i].id == display && !(current.physical[i].flags & RD_BUILTIN) && !(current.physical[i].flags & RD_VIRTUAL)) {
                self.removedExternal = 0;
            }
        }
    }
    [self rememberExternalsFromTopology:current];
    BOOL shouldProcess = RDTopologyShouldProcess(&_topologyGate, current, RDEventDisplayCallback, display);
    // Break the unplug deadlock if ScreensDidSleep arrived milliseconds before kCGDisplayRemoveFlag
    // while the system itself is awake and the builtin screen is still disabled by us with lid open.
    if (self.sleeping && !self.systemSleeping && (flags & kCGDisplayRemoveFlag) && physicalExternal && [self hasHeadlessOwnedBuiltinDeadlock:current]) {
        self.sleeping = NO;
        self.retryAttempt = 0;
        [self requestCheck];
        return;
    }
    if (shouldProcess) [self requestCheck];
}

- (void)startAdoptingExisting:(BOOL)adopting {
    if (self.selfTest) { [self requestCheck]; return; }
    if (adopting || self.sleeping || self.systemSleeping) return;
    [self wake:nil];
}
@end

#ifndef RD_LISTENER_TESTING
static void displayChanged(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *context) {
    if (!(flags & (kCGDisplayAddFlag | kCGDisplayRemoveFlag | kCGDisplayEnabledFlag | kCGDisplayDisabledFlag))) return;
    DisplayWakeListener *listener = (__bridge DisplayWakeListener *)context;
    dispatch_async(dispatch_get_main_queue(), ^{ [listener handleDisplayChange:display flags:flags]; });
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        DisplayWakeListener *listener = [[DisplayWakeListener alloc] initWithTopologyProvider:^{ return RDReadSystemTopology(); } commandRunner:nil];
        listener.selfTest = argc > 1 && strcmp(argv[1], "--self-test") == 0;
        NSNotificationCenter *center = NSWorkspace.sharedWorkspace.notificationCenter;
        [center addObserver:listener selector:@selector(wake:) name:NSWorkspaceDidWakeNotification object:nil];
        [center addObserver:listener selector:@selector(wake:) name:NSWorkspaceScreensDidWakeNotification object:nil];
        [center addObserver:listener selector:@selector(sleep:) name:NSWorkspaceWillSleepNotification object:nil];
        [center addObserver:listener selector:@selector(sleep:) name:NSWorkspaceScreensDidSleepNotification object:nil];
        CGError result = CGDisplayRegisterReconfigurationCallback(displayChanged, (__bridge void *)listener);
        if (result != kCGErrorSuccess) { NSLog(@"display callback registration failed: %d", result); return 1; }
        if (listener.selfTest) {
            [listener requestCheck];
        } else {
            NSString *handoff = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/RustDeskAppCompanion/listener-adopt-once"];
            BOOL adoption = argc > 1 && strcmp(argv[1], "--rd-adopt-running") == 0;
            if ([[NSFileManager defaultManager] fileExistsAtPath:handoff]) {
                adoption = [[NSFileManager defaultManager] removeItemAtPath:handoff error:nil] || adoption;
            }
            [listener startAdoptingExisting:adoption];
        }
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
#endif

// Keeps every booted iOS Simulator's sound on BlackHole, whatever the Mac's own output is set to.
//
// A Simulator's output starts as "follow the Mac's default", so test runs play through the speakers whenever the
// owner chooses them. This does what the Simulator's I/O > Audio Output menu does, for each booted device, and never
// reads or sets the Mac's default devices (that was #1568, reverted: it made AirPods flip every second). Only the
// Simulator's output changes. Its microphone setting stays as it is.
//
// It uses CoreSimulator's private audio routing call, because there is no simctl command for this. An Xcode update
// could change that call: `--status` then shows the Simulators back on "follows the Mac", and the log says why.
//
//   sim-audio-pin            run for good (launchd starts it; see install-sim-audio-pin.sh)
//   sim-audio-pin --status   print each booted Simulator's output; exit 1 when one is not on BlackHole
//   sim-audio-pin --blackhole  exit 0 when this Mac has BlackHole 2ch, 1 when not (the host test uses it)
//
// A failure it can't fix (BlackHole missing, the route call refused) also shows a Mac notification, at most once every
// six hours, because a log nobody reads hid a dead pin for two days (2026-11-08 to 11-10).
#import <CoreAudio/CoreAudio.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>

#pragma clang diagnostic ignored "-Warc-performSelector-leaks"

static NSString *const kBlackHole = @"BlackHole2ch_UID";
static const unsigned long long kScopeOutput = 2;  // 1 is the microphone; read from a live Simulator, 2026-11-08
static const int kStateBooted = 3;
static const NSTimeInterval kScanSeconds = 2;      // no audio starts this soon after a Simulator reports booted
static const NSTimeInterval kRecheckSeconds = 15;  // catches someone changing the Simulator's menu
static const NSTimeInterval kLifetimeSeconds = 3600;  // launchd restarts it: picks up an Xcode update, caps any leak

static NSMutableDictionary<NSString *, NSDate *> *nextCheck;
static NSMutableSet<NSString *> *complained;
static NSDate *started;

static void say(NSString *line) {
    NSDateFormatter *clock = [NSDateFormatter new];
    clock.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    fprintf(stderr, "%s %s\n", [clock stringFromDate:NSDate.date].UTF8String, line.UTF8String);
}

// A Mac notification, at most once every six hours across restarts, so a pin that can't work gets seen.
static void notifyOwner(NSString *line) {
    NSString *stamp = [NSHomeDirectory() stringByAppendingPathComponent:@"SpokenMarginsOps/audio-loopback/last-notice"];
    NSDate *last = [NSFileManager.defaultManager attributesOfItemAtPath:stamp error:nil].fileModificationDate;
    if (last && -last.timeIntervalSinceNow < 6 * 3600) return;
    [@"" writeToFile:stamp atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSString *quoted = [[line stringByReplacingOccurrencesOfString:@"\\" withString:@""]
                        stringByReplacingOccurrencesOfString:@"\"" withString:@"'"];
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/osascript"];
    task.arguments = @[@"-e", [NSString stringWithFormat:
        @"display notification \"%@\" with title \"Simulator sound may reach your speakers\"", quoted]];
    [task launchAndReturnError:nil];
}

static void complainOnce(NSString *line) {
    if ([complained containsObject:line]) return;
    [complained addObject:line];
    say(line);
    notifyOwner(line);
}

static NSString *developerDir(void) {
    NSString *chosen = NSProcessInfo.processInfo.environment[@"DEVELOPER_DIR"];
    if (chosen.length) return chosen;
    FILE *pipe = popen("/usr/bin/xcode-select -p", "r");
    char line[1024] = {0};
    if (pipe) {
        fgets(line, sizeof line, pipe);
        pclose(pipe);
    }
    NSString *found = [@(line) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return found.length ? found : @"/Applications/Xcode.app/Contents/Developer";
}

// The default device set plus the clones xcodebuild makes for tests, when the set can be opened.
static NSArray *deviceSets(id context) {
    NSMutableArray *sets = [NSMutableArray array];
    NSError *error = nil;
    id fallback = ((id(*)(id, SEL, NSError **))objc_msgSend)(context, NSSelectorFromString(@"defaultDeviceSetWithError:"), &error);
    if (fallback) [sets addObject:fallback];
    else complainOnce([NSString stringWithFormat:@"could not open the Simulator device set: %@", error]);
    NSString *clones = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Developer/XCTestDevices"];
    if ([NSFileManager.defaultManager fileExistsAtPath:clones]) {
        id set = ((id(*)(id, SEL, NSString *, NSError **))objc_msgSend)(context, NSSelectorFromString(@"deviceSetWithPath:error:"), clones, &error);
        if (set) [sets addObject:set];
    }
    return sets;
}

static id audioRouter(id device) {
    SEL route = NSSelectorFromString(@"routeGuestDeviceScope:toHostDeviceUID:completionQueue:completionHandler:");
    SEL descriptor = NSSelectorFromString(@"descriptor");
    id io = [device valueForKey:@"io"];
    for (id port in [io performSelector:NSSelectorFromString(@"ioPorts")]) {
        id candidate = [port respondsToSelector:descriptor] ? [port performSelector:descriptor] : nil;
        if ([candidate respondsToSelector:route]) return candidate;
    }
    return nil;
}

static NSString *currentOutput(id router) {
    return [router performSelector:NSSelectorFromString(@"guestOutputHostDeviceUID")];
}

// Asks the Mac's own audio system. The router's availableHostDevices can't answer this: it returns remote proxies
// whose description is only "ROCKImmutableProxy", so a check against it said "no BlackHole" every time and the pin
// never pinned anything (2026-11-08 to 11-10). The check still matters: routing to a UID the Mac lacks reports no
// error and quietly lands on the speakers (tried 2026-11-10).
static BOOL blackHoleExists(void) {
    CFStringRef uid = (__bridge CFStringRef)kBlackHole;
    AudioObjectID device = kAudioObjectUnknown;
    AudioValueTranslation query = {&uid, sizeof uid, &device, sizeof device};
    UInt32 size = sizeof query;
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyDeviceForUID, kAudioObjectPropertyScopeGlobal,
                                          kAudioObjectPropertyElementMain};
    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &query);
    return status == noErr && device != kAudioObjectUnknown;
}

static NSError *routeToBlackHole(id router) {
    SEL route = NSSelectorFromString(@"routeGuestDeviceScope:toHostDeviceUID:completionQueue:completionHandler:");
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    __block NSError *failure = nil;
    void (^done)(NSError *) = ^(NSError *error) {
        failure = error;
        dispatch_semaphore_signal(finished);
    };
    ((void (*)(id, SEL, unsigned long long, NSString *, dispatch_queue_t, id))objc_msgSend)(
        router, route, kScopeOutput, kBlackHole, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), done);
    if (dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) != 0) {
        return [NSError errorWithDomain:@"sim-audio-pin" code:1
                               userInfo:@{NSLocalizedDescriptionKey: @"the route call did not answer in 10 s"}];
    }
    return failure;
}

static void pinDevice(id device) {
    NSString *udid = [[device valueForKey:@"UDID"] UUIDString];
    NSDate *due = nextCheck[udid];
    if (due && due.timeIntervalSinceNow > 0) return;
    NSString *name = [device valueForKey:@"name"];
    id router = audioRouter(device);
    if (!router) return;  // still starting up; the next scan tries again
    if ([currentOutput(router) isEqual:kBlackHole]) {
        nextCheck[udid] = [NSDate dateWithTimeIntervalSinceNow:kRecheckSeconds];
        return;
    }
    if (!blackHoleExists()) {
        complainOnce(@"BlackHole 2ch is not an audio device on this Mac; Simulators follow the Mac's output");
        return;
    }
    NSString *before = currentOutput(router);
    NSError *error = routeToBlackHole(router);
    if (error) {
        complainOnce([NSString stringWithFormat:@"could not pin %@: %@", name, error.localizedDescription]);
        return;
    }
    NSString *after = currentOutput(router);
    if (![after isEqual:kBlackHole]) {
        complainOnce([NSString stringWithFormat:@"could not pin %@: the route call answered but output is %@", name, after]);
        return;
    }
    say([NSString stringWithFormat:@"pinned %@ (%@): output was %@, now %@", name, udid, before, after]);
    nextCheck[udid] = [NSDate dateWithTimeIntervalSinceNow:kRecheckSeconds];
}

// What device.plist says on disk. CoreSimulator's in-process list only stays current through its own notifications,
// so a Simulator the disk calls booted but the list doesn't means the list is stale: exit, and launchd starts afresh.
static NSSet<NSString *> *bootedOnDisk(void) {
    NSMutableSet *booted = [NSMutableSet set];
    NSFileManager *files = NSFileManager.defaultManager;
    for (NSString *relative in @[@"Library/Developer/CoreSimulator/Devices", @"Library/Developer/XCTestDevices"]) {
        NSString *root = [NSHomeDirectory() stringByAppendingPathComponent:relative];
        for (NSString *udid in [files contentsOfDirectoryAtPath:root error:nil]) {
            NSString *plist = [[root stringByAppendingPathComponent:udid] stringByAppendingPathComponent:@"device.plist"];
            NSDictionary *contents = [NSDictionary dictionaryWithContentsOfFile:plist];
            if ([contents[@"state"] intValue] == kStateBooted) [booted addObject:udid];
        }
    }
    return booted;
}

static void scan(NSArray *sets) {
    @autoreleasepool {
        if (-started.timeIntervalSinceNow > kLifetimeSeconds) exit(0);
        NSMutableSet *listed = [NSMutableSet set];
        for (id set in sets) {
            for (id device in [set valueForKey:@"devices"]) {
                if ([[device valueForKey:@"state"] intValue] != kStateBooted) continue;
                [listed addObject:[[device valueForKey:@"UDID"] UUIDString]];
                pinDevice(device);
            }
        }
        NSMutableSet *missed = [bootedOnDisk() mutableCopy];
        [missed minusSet:listed];
        if (missed.count) {
            say([NSString stringWithFormat:@"device list is stale (%@ booted on disk); restarting", missed.anyObject]);
            exit(0);
        }
    }
}

static int status(NSArray *sets) {
    int shown = 0, loose = 0;
    for (id set in sets) {
        for (id device in [set valueForKey:@"devices"]) {
            if ([[device valueForKey:@"state"] intValue] != kStateBooted) continue;
            id router = audioRouter(device);
            NSString *output = router ? currentOutput(router) : @"still starting";
            printf("%s: %s\n", [[device valueForKey:@"name"] UTF8String], output.UTF8String);
            if (![output isEqual:kBlackHole]) loose++;
            shown++;
        }
    }
    if (!shown) printf("no Simulator is booted\n");
    if (!blackHoleExists()) { printf("BlackHole 2ch is not an audio device on this Mac\n"); return 1; }
    return loose ? 1 : 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        nextCheck = [NSMutableDictionary dictionary];
        complained = [NSMutableSet set];
        started = NSDate.date;
        if (argc > 1 && !strcmp(argv[1], "--blackhole")) return blackHoleExists() ? 0 : 1;
        if (!dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW)) {
            say(@"CoreSimulator is not installed");
            return 1;
        }
        NSError *error = nil;
        id context = ((id(*)(id, SEL, NSString *, NSError **))objc_msgSend)(
            NSClassFromString(@"SimServiceContext"), NSSelectorFromString(@"sharedServiceContextForDeveloperDir:error:"),
            developerDir(), &error);
        if (!context) {
            say([NSString stringWithFormat:@"could not reach CoreSimulator: %@", error]);
            return 1;
        }
        NSArray *sets = deviceSets(context);
        if (argc > 1 && !strcmp(argv[1], "--status")) return status(sets);
        say(@"started");
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, (uint64_t)(kScanSeconds * NSEC_PER_SEC), NSEC_PER_SEC / 2);
        dispatch_source_set_event_handler(timer, ^{ scan(sets); });
        dispatch_resume(timer);
        dispatch_main();
    }
}

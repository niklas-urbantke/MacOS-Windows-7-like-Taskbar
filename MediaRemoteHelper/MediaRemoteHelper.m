// MediaRemote-Helfer für Win7Taskbar.
//
// Seit macOS 15.4 liefert MediaRemote.framework fremden Apps keine systemweite
// Wiedergabe-Info mehr (leeres Dictionary). Apple-signierte Programme wie /usr/bin/perl
// dürfen es weiterhin. Deshalb lädt mediaremote-helper.pl diese dylib in Perl und ruft
// mr_run() auf, das nie zurückkehrt:
//
//   stdout: pro Zustandsänderung eine JSON-Zeile (siehe emit()).
//   stdin:  Befehle, je Zeile einer: toggle | play | pause | next | prev | seek <sek> | refresh
//           Ende von stdin (App beendet) beendet den Prozess.
//
// Bauen: clang -dynamiclib -fobjc-arc -arch arm64 -arch x86_64 -framework Foundation \
//        -o libmediaremote-helper.dylib MediaRemoteHelper.m

#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <dlfcn.h>
#import <libproc.h>
#import <signal.h>
#import <unistd.h>

// MARK: - Private MediaRemote-API (per dlsym)

typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRGetClientFn)(dispatch_queue_t, void (^)(id));
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*MRGetIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef CFStringRef (*MRClientStringFn)(id);
typedef Boolean (*MRSendCommandFn)(int, CFDictionaryRef);
typedef void (*MRSetElapsedFn)(double);
typedef void (*MRRegisterFn)(dispatch_queue_t);

static MRGetInfoFn MRGetInfo;
static MRGetClientFn MRGetClient;
static MRGetPIDFn MRGetPID;
static MRGetIsPlayingFn MRGetIsPlaying;
static MRClientStringFn MRClientBundleID;
static MRClientStringFn MRClientParentBundleID;
static MRSendCommandFn MRSendCommand;
static MRSetElapsedFn MRSetElapsed;
static MRRegisterFn MRRegister;

enum { kMRPlay = 0, kMRPause = 1, kMRTogglePlayPause = 2, kMRNextTrack = 4, kMRPreviousTrack = 5 };

// MARK: - Zustand (nur auf `queue` benutzt)

static dispatch_queue_t queue;
static BOOL fetching = NO;        // gerade läuft eine Abfrage
static BOOL refetch = NO;         // während der Abfrage kam ein neuer Anlass
static NSDictionary *lastSent;    // zuletzt gemeldeter Zustand (ohne hochgerechnete Werte)
static NSString *lastArtworkID = @"";
static NSString *artworkTrack = @"";   // Titel, zu dem lastArtworkID gehört
static dispatch_source_t stdinSource, pollTimer;   // am Leben halten

// MARK: - Ausgabe

static void writeLine(NSData *data) {
    const char *p = data.bytes;
    size_t left = data.length;
    while (left > 0) {
        ssize_t n = write(STDOUT_FILENO, p, left);
        if (n < 0) {
            if (errno == EINTR) continue;
            exit(0);              // Leser weg: App beendet
        }
        p += n; left -= (size_t)n;
    }
    write(STDOUT_FILENO, "\n", 1);
}

static NSString *str(id v) { return [v isKindOfClass:NSString.class] ? v : @""; }
static double num(id v) { return [v isKindOfClass:NSNumber.class] ? [v doubleValue] : 0; }

/// Kennung des Covers: MediaRemote liefert meist eine, sonst Hash der Bilddaten.
static NSString *artworkIdentifier(NSDictionary *info, NSData *art) {
    if (!art.length) return @"";
    NSString *ident = str(info[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"]);
    if (ident.length) return ident;
    unsigned char d[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(art.bytes, (CC_LONG)art.length, d);
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < 8; i++) [s appendFormat:@"%02x", d[i]];
    return s;
}

/// Bundle-ID über den Pfad des Prozesses (Rückfall, falls der Client keine liefert).
static NSString *bundleIDForPID(int pid) {
    if (pid <= 0) return @"";
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(pid, path, sizeof path) <= 0) return @"";
    NSString *p = @(path);
    // Äußerstes .app im Pfad nehmen (Helfer-Prozesse liegen in Contents/Frameworks/…).
    NSRange r = [p rangeOfString:@".app/"];
    if (r.location == NSNotFound) return @"";
    NSString *app = [p substringToIndex:r.location + 4];
    return [NSBundle bundleWithPath:app].bundleIdentifier ?: @"";
}

/// Schreibt eine Zeile, wenn sich gegenüber der letzten Meldung etwas geändert hat.
///   title, artist, album, duration, elapsed (auf jetzt hochgerechnet), rate, playing,
///   bundleID, pid, artworkID; artwork (Base64) und artworkMIME nur, wenn das Cover neu ist.
static void emit(NSDictionary *info, NSString *bundleID, int pid, BOOL isPlaying) {
    double rate = num(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]);
    double elapsed = num(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]);
    id tsObj = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    double ts = [tsObj isKindOfClass:NSDate.class] ? [tsObj timeIntervalSince1970] : 0;
    NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    if (![art isKindOfClass:NSData.class]) art = nil;
    NSString *artID = artworkIdentifier(info, art);
    NSString *title = str(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
    NSString *artist = str(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
    NSString *album = str(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
    // Manche Player (Tidal) melden zwischendurch denselben Titel ohne Cover. Dann das
    // bisherige behalten, statt es wegzunehmen und gleich darauf erneut zu senden.
    NSString *track = [NSString stringWithFormat:@"%@|%@|%@", title, artist, album];
    if (!art.length && title.length && [track isEqualToString:artworkTrack]) artID = lastArtworkID;
    else if (art.length) artworkTrack = track;

    NSDictionary *state = @{
        @"title": title,
        @"artist": artist,
        @"album": album,
        @"duration": @(num(info[@"kMRMediaRemoteNowPlayingInfoDuration"])),
        @"rate": @(rate),
        @"playing": @(isPlaying),
        @"bundleID": bundleID ?: @"",
        @"pid": @(pid),
        @"artworkID": artID,
        // Rohwerte nur für den Vergleich: ändern sich bei Sprung/Pause, nicht beim Weiterlaufen.
        @"_elapsed": @(elapsed),
        @"_ts": @(ts),
    };
    if ([state isEqualToDictionary:lastSent]) return;
    lastSent = state;

    NSMutableDictionary *out = [state mutableCopy];
    [out removeObjectForKey:@"_elapsed"];
    [out removeObjectForKey:@"_ts"];
    double now = NSDate.date.timeIntervalSince1970;
    double pos = elapsed;
    if (ts > 0 && isPlaying && rate > 0) pos += (now - ts) * rate;
    out[@"elapsed"] = @(MAX(0, pos));
    out[@"time"] = @(now);
    if (![artID isEqualToString:lastArtworkID]) {
        lastArtworkID = artID;
        if (art.length) {
            out[@"artwork"] = [art base64EncodedStringWithOptions:0];
            out[@"artworkMIME"] = str(info[@"kMRMediaRemoteNowPlayingInfoArtworkMIMEType"]);
        }
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
    if (json) writeLine(json);
}

// MARK: - Abfrage

static void refresh(void);

static void finishFetch(void) {
    fetching = NO;
    if (refetch) { refetch = NO; refresh(); }
}

/// Holt Info, spielende App und Wiedergabestatus nacheinander (alles auf `queue`).
static void refresh(void) {
    if (fetching) { refetch = YES; return; }
    fetching = YES;
    MRGetInfo(queue, ^(NSDictionary *info) {
        if (![info isKindOfClass:NSDictionary.class] || info.count == 0) {
            emit(@{}, @"", 0, NO);
            finishFetch();
            return;
        }
        MRGetClient(queue, ^(id client) {
            NSString *bid = @"";
            if (client) {
                // Bei eingebetteten Wiedergaben (z. B. WebKit-Prozess) zählt die Eltern-App.
                if (MRClientParentBundleID) bid = (__bridge NSString *)MRClientParentBundleID(client) ?: @"";
                if (!bid.length && MRClientBundleID) bid = (__bridge NSString *)MRClientBundleID(client) ?: @"";
            }
            MRGetPID(queue, ^(int pid) {
                NSString *b = bid.length ? bid : bundleIDForPID(pid);
                if (MRGetIsPlaying) {
                    MRGetIsPlaying(queue, ^(Boolean playing) {
                        emit(info, b, pid, playing);
                        finishFetch();
                    });
                } else {
                    emit(info, b, pid, num(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]) > 0);
                    finishFetch();
                }
            });
        });
    });
}

static void refreshSoon(double seconds) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), queue, ^{ refresh(); });
}

// MARK: - Befehle

static void handleCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSString *cmd = parts.firstObject.lowercaseString;
    if ([cmd isEqualToString:@"toggle"]) MRSendCommand(kMRTogglePlayPause, NULL);
    else if ([cmd isEqualToString:@"play"]) MRSendCommand(kMRPlay, NULL);
    else if ([cmd isEqualToString:@"pause"]) MRSendCommand(kMRPause, NULL);
    else if ([cmd isEqualToString:@"next"]) MRSendCommand(kMRNextTrack, NULL);
    else if ([cmd isEqualToString:@"prev"]) MRSendCommand(kMRPreviousTrack, NULL);
    else if ([cmd isEqualToString:@"seek"] && parts.count > 1 && MRSetElapsed) MRSetElapsed(MAX(0, parts[1].doubleValue));
    else if (![cmd isEqualToString:@"refresh"]) return;
    refresh();
    refreshSoon(0.25);
    refreshSoon(0.8);
}

static void startStdinReader(void) {
    static NSMutableData *buffer;
    buffer = [NSMutableData data];
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, queue);
    dispatch_source_set_event_handler(src, ^{
        char chunk[4096];
        ssize_t n = read(STDIN_FILENO, chunk, sizeof chunk);
        if (n == 0 || (n < 0 && errno != EINTR && errno != EAGAIN)) exit(0);   // App beendet
        if (n < 0) return;
        [buffer appendBytes:chunk length:(NSUInteger)n];
        for (;;) {
            NSRange nl = [buffer rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0
                                       range:NSMakeRange(0, buffer.length)];
            if (nl.location == NSNotFound) break;
            NSData *lineData = [buffer subdataWithRange:NSMakeRange(0, nl.location)];
            [buffer replaceBytesInRange:NSMakeRange(0, nl.location + 1) withBytes:NULL length:0];
            NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
            line = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (line.length) handleCommand(line);
        }
    });
    dispatch_resume(src);
    stdinSource = src;
}

// MARK: - Einstieg

static void noClient(dispatch_queue_t q, void (^cb)(id)) { dispatch_async(q, ^{ cb(nil); }); }
static void noPID(dispatch_queue_t q, void (^cb)(int)) { dispatch_async(q, ^{ cb(0); }); }

/// Aufgerufen aus Perl. Kehrt nicht zurück; endet mit exit(), wenn stdin schließt.
void mr_run(void) {
    signal(SIGPIPE, SIG_DFL);
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!h) { fprintf(stderr, "MediaRemote nicht ladbar\n"); exit(2); }
    MRGetInfo = (MRGetInfoFn)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    MRGetClient = (MRGetClientFn)dlsym(h, "MRMediaRemoteGetNowPlayingClient");
    MRGetPID = (MRGetPIDFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationPID");
    MRGetIsPlaying = (MRGetIsPlayingFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    MRClientBundleID = (MRClientStringFn)dlsym(h, "MRNowPlayingClientGetBundleIdentifier");
    MRClientParentBundleID = (MRClientStringFn)dlsym(h, "MRNowPlayingClientGetParentAppBundleIdentifier");
    MRSendCommand = (MRSendCommandFn)dlsym(h, "MRMediaRemoteSendCommand");
    MRSetElapsed = (MRSetElapsedFn)dlsym(h, "MRMediaRemoteSetElapsedTime");
    MRRegister = (MRRegisterFn)dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!MRGetInfo || !MRSendCommand) { fprintf(stderr, "MediaRemote-Symbole fehlen\n"); exit(2); }
    // Fehlende Hilfsfunktionen überbrücken, damit refresh() nicht verzweigen muss.
    if (!MRGetClient) MRGetClient = noClient;
    if (!MRGetPID) MRGetPID = noPID;

    queue = dispatch_queue_create("win7taskbar.mediaremote", DISPATCH_QUEUE_SERIAL);

    if (MRRegister) MRRegister(queue);
    NSArray *names = @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                       @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                       @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                       @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange",
                       @"kMRMediaRemoteNowPlayingPlaybackQueueChangedNotification"];
    for (NSString *n in names) {
        [NSNotificationCenter.defaultCenter addObserverForName:n object:nil queue:nil
                                                    usingBlock:^(NSNotification *note) {
            dispatch_async(queue, ^{ refresh(); });
        }];
    }

    // Ruhiger Takt als Rückfallebene, falls eine Benachrichtigung ausbleibt.
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    pollTimer = timer;
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC,
                              NSEC_PER_SEC / 5);
    dispatch_source_set_event_handler(timer, ^{ refresh(); });
    dispatch_resume(timer);

    startStdinReader();
    dispatch_async(queue, ^{ refresh(); });
    CFRunLoopRun();
    exit(0);
}

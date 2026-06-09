// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Magenta AU Template view controller — hosts the React UI in a WKWebView.
// Simplified from MagentaRTAppController: single prompt, MIDI/waveform visualization.

#import "MagentaAU_AudioUnit.h"
#import <CoreAudioKit/CoreAudioKit.h>
#import <WebKit/WebKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <AudioToolbox/AudioToolbox.h>
#import "MagentaModelManager.h"
#import "MagentaModelDownloader.h"
#import "MagentaSettings.h"
#include "magenta_paths.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>

using magentart::core::RealtimeRunner;
using magentart::core::EngineMetrics;

// ─── Models folder helpers (aligned with mrt2-au3 AU sandbox patterns) ───────

static NSData* MGRTModelsFolderBookmark(void) {
    NSData* bookmark = [[NSUserDefaults standardUserDefaults] objectForKey:@"DownloadFolderBookmark"];
    if (!bookmark) {
        bookmark = [[NSUserDefaults standardUserDefaults] objectForKey:@"MagentaRT_ModelFolderBookmark"];
    }
    return bookmark;
}

static void MGRTSaveModelsFolderBookmark(NSString* path, NSData* bookmarkData) {
    if (!path || !bookmarkData) return;
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:bookmarkData forKey:@"DownloadFolderBookmark"];
    [defaults setObject:path forKey:@"DownloadFolderPath"];
    [defaults setObject:bookmarkData forKey:@"MagentaRT_ModelFolderBookmark"];
    [defaults setObject:path forKey:@"MagentaRT_ModelFolderPath"];
}

static NSURL* MGRTURLFromPath(NSString* path) {
    return path.length > 0 ? [NSURL fileURLWithPath:path isDirectory:YES] : nil;
}

static NSArray<NSURL*>* MGRTModelsSearchCandidates(NSURL* baseURL) {
    NSMutableOrderedSet<NSURL*>* candidates = [NSMutableOrderedSet orderedSet];
    void (^addPath)(NSString*) = ^(NSString* path) {
        NSURL* url = MGRTURLFromPath(path);
        if (url) [candidates addObject:url];
    };

    if (baseURL) {
        [candidates addObject:baseURL];
        addPath([baseURL.path stringByAppendingPathComponent:@"models"]);
        addPath([baseURL.path stringByAppendingPathComponent:@"magenta-rt-v2/models"]);
    }

    for (NSString* path in [MagentaModelManager defaultModelsSearchPaths]) {
        addPath(path);
        addPath([path stringByAppendingPathComponent:@"models"]);
        addPath([path stringByAppendingPathComponent:@"magenta-rt-v2/models"]);
    }

    return candidates.array;
}

/// Resolve the first directory under `baseURL` (or standard Magenta layouts) that contains models.
static NSURL* MGRTEffectiveModelsDirectoryURL(NSURL* baseURL) {
    for (NSURL* candidate in MGRTModelsSearchCandidates(baseURL)) {
        NSArray<NSString*>* models = [MagentaModelManager listLocalModelsInDirectory:candidate];
        if (models.count > 0) {
            if (baseURL && ![candidate.path isEqualToString:baseURL.path]) {
                NSLog(@"MagentaAU: using models directory %@", candidate.path);
            }
            return candidate;
        }
    }
    if (baseURL) return baseURL;
    return MGRTURLFromPath([MagentaModelManager defaultModelsDirectory]);
}

static NSString* MGRTResolveResourcesPath(void) {
    for (NSString* path in [MagentaModelDownloader defaultResourceSearchPaths]) {
        if ([MagentaModelDownloader resourcesValidAtPath:path]) {
            return path;
        }
    }
    return [NSString stringWithUTF8String:magentart::paths::get_resources_dir().c_str()];
}

static BOOL MGRTSharedResourcesAvailable(MagentaAUAudioUnit* au) {
    if ([MagentaModelDownloader areSharedResourcesValid]) {
        return YES;
    }
    return au && [au hasInitializedAssets];
}

/// Resolve bookmarked (or default) models directory. Optionally returns scoped base URL for stopAccessing.
static NSURL* MGRTResolveModelsDirectory(BOOL* outAccessGranted, NSURL** outScopedBaseURL) {
    if (outAccessGranted) *outAccessGranted = NO;
    if (outScopedBaseURL) *outScopedBaseURL = nil;

    NSURL* baseURL = nil;
    NSData* bookmark = MGRTModelsFolderBookmark();
    if (bookmark) {
        BOOL stale = NO;
        NSError* error = nil;
        baseURL = [NSURL URLByResolvingBookmarkData:bookmark
                                            options:NSURLBookmarkResolutionWithSecurityScope | NSURLBookmarkResolutionWithoutUI
                                      relativeToURL:nil
                                bookmarkDataIsStale:&stale
                                              error:&error];
        if (error) {
            NSLog(@"MagentaAU: bookmark resolve failed: %@", error.localizedDescription);
        } else if (stale) {
            NSLog(@"MagentaAU: bookmark is stale for %@", baseURL.path);
        }
        if (baseURL) {
            BOOL accessGranted = [baseURL startAccessingSecurityScopedResource];
            if (outAccessGranted) *outAccessGranted = accessGranted;
            if (outScopedBaseURL) *outScopedBaseURL = baseURL;
            if (!accessGranted) {
                NSLog(@"MagentaAU: startAccessingSecurityScopedResource failed for %@", baseURL.path);
            }
        }
    }

    if (!baseURL) {
        std::string defaultPath = magentart::paths::get_models_dir();
        baseURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:defaultPath.c_str()]];
    }

    return MGRTEffectiveModelsDirectoryURL(baseURL);
}

static void MGRTEnsureCustomResourcesPath(void) {
    NSString* current = [[NSUserDefaults standardUserDefaults] objectForKey:@"MagentaRT_CustomResourcesPath"];
    if (current.length > 0 && [MagentaModelDownloader resourcesValidAtPath:current]) {
        return;
    }
    NSString* resolved = MGRTResolveResourcesPath();
    if ([MagentaModelDownloader resourcesValidAtPath:resolved]) {
        [[NSUserDefaults standardUserDefaults] setObject:resolved forKey:@"MagentaRT_CustomResourcesPath"];
        NSLog(@"MagentaAU: using resources at %@", resolved);
    }
}

static NSString* MGRTSandboxAwareResourcesPath(NSString* selectedPath) {
    if (selectedPath.length == 0) {
        return MGRTResolveResourcesPath();
    }

    NSArray<NSString*>* candidates = @[
        selectedPath,
        [selectedPath stringByAppendingPathComponent:@"resources"],
        [selectedPath stringByAppendingPathComponent:@"magenta-rt-v2/resources"],
    ];
    for (NSString* candidate in candidates) {
        if ([MagentaModelDownloader resourcesValidAtPath:candidate]) {
            return candidate;
        }
    }
    return MGRTResolveResourcesPath();
}

static NSString* MGRTPreferredModelName(NSArray<NSString*>* modelFiles) {
    if (modelFiles.count == 0) return nil;
    NSString* preferred = [[NSUserDefaults standardUserDefaults] stringForKey:@"LoadedModelName"];
    if (preferred.length > 0 && [modelFiles containsObject:preferred]) {
        return preferred;
    }
    preferred = [[NSUserDefaults standardUserDefaults] stringForKey:@"MGTAU_LoadedModelName"];
    if (preferred.length > 0 && [modelFiles containsObject:preferred]) {
        return preferred;
    }
    if ([modelFiles containsObject:@"mrt2_small"]) {
        return @"mrt2_small";
    }
    return modelFiles[0];
}

// ─── Dev server probe ────────────────────────────────────────────────────────

static const int kMagentaAUDevServerPort = 62422;

static BOOL isDevServerRunning(void) {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return NO;
    struct timeval tv = { .tv_sec = 0, .tv_usec = 100000 }; // 100ms
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    struct sockaddr_in addr = {};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kMagentaAUDevServerPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    BOOL up = (connect(sock, (struct sockaddr*)&addr, sizeof(addr)) == 0);
    close(sock);
    return up;
}

// ─── WKWebView subclass for keyboard shortcuts ──────────────────────────────

@interface MagentaAUWebView : WKWebView
@end

@implementation MagentaAUWebView
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if ([event modifierFlags] & NSEventModifierFlagCommand) {
        NSString *chars = [event charactersIgnoringModifiers];
        if ([chars isEqualToString:@"c"]) { [NSApp sendAction:@selector(copy:) to:nil from:self]; return YES; }
        else if ([chars isEqualToString:@"v"]) { [NSApp sendAction:@selector(paste:) to:nil from:self]; return YES; }
        else if ([chars isEqualToString:@"a"]) { [NSApp sendAction:@selector(selectAll:) to:nil from:self]; return YES; }
        else if ([chars isEqualToString:@"x"]) { [NSApp sendAction:@selector(cut:) to:nil from:self]; return YES; }
    }
    return [super performKeyEquivalent:event];
}
@end

// ─── Param helpers ───────────────────────────────────────────────────────────





// Addresses of params to persist across launches


// ─── View Controller ─────────────────────────────────────────────────────────

@interface MagentaAUViewController () <WKScriptMessageHandler, WKNavigationDelegate, AUAudioUnitFactory>
- (void)handleSelectDownloadFolder;
- (void)handleListLocalModels;
- (void)handleSelectModel:(NSString*)modelName;
- (void)handleDeleteModel:(NSString*)modelName;
- (void)handleInitResources:(NSString*)modelName;
- (BOOL)loadModelAtPath:(NSString*)mlxfnPath;
- (NSString*)mlxfnPathForModelAtURL:(NSURL*)modelURL;
- (void)saveLoadedModelBookmarkForURL:(NSURL*)modelURL modelName:(NSString*)modelName;
- (void)autoLoadSavedModelIfNeeded;
- (void)tryAutoLoadFromModelsDirectory;
- (BOOL)decodeAudioPromptAtURL:(NSURL*)url
                           index:(int)index
                        filename:(NSString*)fallbackName;
- (void)finishAudioPromptLoad:(NSString*)displayName index:(int)index success:(BOOL)success;
- (void)loadAudioPromptFromURL:(NSURL*)url index:(int)index accessGranted:(BOOL)accessGranted;
- (void)loadAudioPromptFromData:(NSData*)data filename:(NSString*)filename index:(int)index;
@end

@implementation MagentaAUViewController {
    AUAudioUnit* _audioUnit;
    WKWebView* _webView;
    NSTimer* _metricsTimer;
    NSMutableDictionary* _lastParams;
    int _metricsTicks;

    NSString* _modelName;
    NSString* _currentPromptText;
    BOOL _isPlaying;
}

// ─── Parameter bridging ──────────────────────────────────────────────────────


- (AUAudioUnit*)createAudioUnitWithComponentDescription:(AudioComponentDescription)desc
                                                  error:(NSError**)error {
    _audioUnit = [[MagentaAUAudioUnit alloc] initWithComponentDescription:desc options:0 error:error];
    return _audioUnit;
}

- (MagentaAUAudioUnit*)jamAU {
    return (MagentaAUAudioUnit*)_audioUnit;
}

- (RealtimeRunner*)engine {
    MagentaAUAudioUnit* au = [self jamAU];
    return au ? [au engine] : nullptr;
}

- (void)applyParamToEngine:(int)address value:(float)value {
    RealtimeRunner* engine = [self engine];
    if (!engine) return;

    [MagentaSettings applyParamToEngine:engine address:address value:value prefixString:@"MGTAU"];

    MagentaAUAudioUnit* au = [self jamAU];
    if (au) {
        AUParameter* param = [au.parameterTree parameterWithAddress:address];
        if (param) [param setValue:value originator:nil];
    }

    if (address == 4) {
        if ([[self jamAU] cfgNotesSliderValue]) {
            [[self jamAU] cfgNotesSliderValue]->store(value, std::memory_order_relaxed);
        }
    }
}

- (void)restoreSavedParams {
    [MagentaSettings restoreSavedParams:[self engine] prefixString:@"MGTAU"];
}

- (float)readParamFromEngine:(int)address {
    if (address == 4) {
        return [[self jamAU] cfgNotesSliderValue] ? [[self jamAU] cfgNotesSliderValue]->load(std::memory_order_relaxed) : kMagentaDefaultCfgNotes;
    }
    return [MagentaSettings readParamFromEngine:[self engine] address:address];
}

// ─── View lifecycle ──────────────────────────────────────────────────────────

- (void)loadView {
    NSView* view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 850, 605)];
    view.wantsLayer = YES;
    view.layer.backgroundColor = [NSColor colorWithRed:0.96 green:0.94 blue:0.94 alpha:1.0].CGColor;
    self.view = view;
    self.preferredContentSize = NSMakeSize(850, 605);
}

- (void)viewWillAppear {
    [super viewWillAppear];

    if (!_webView) {
        WKWebViewConfiguration* config = [[WKWebViewConfiguration alloc] init];
        [config.preferences setValue:@YES forKey:@"developerExtrasEnabled"];
        [config.preferences setValue:@YES forKey:@"allowFileAccessFromFileURLs"];
        @try { [config setValue:@YES forKey:@"allowUniversalAccessFromFileURLs"]; } @catch (NSException *e) { }

        NSString *js = @"window.__HOST_MODE__ = 'auv3';"
                       @"window.onerror = function(msg, url, line, col, error) { window.webkit.messageHandlers.auHost.postMessage({type:'log', value:'JS Error: '+msg+ ' @ line '+line}); };"
                       @"var origLog = console.log; console.log = function(msg) { window.webkit.messageHandlers.auHost.postMessage({type:'log', value:''+msg}); origLog(msg); };";
        WKUserScript *script = [[WKUserScript alloc] initWithSource:js injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES];
        [config.userContentController addUserScript:script];
        [config.userContentController addScriptMessageHandler:self name:@"auHost"];

        _webView = [[MagentaAUWebView alloc] initWithFrame:self.view.bounds configuration:config];
        _webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _webView.navigationDelegate = self;
        [_webView setValue:@(NO) forKey:@"drawsBackground"];
        [self.view addSubview:_webView];

        if (isDevServerRunning()) {
            NSLog(@"Jam: Vite dev server detected on port %d — loading with HMR", kMagentaAUDevServerPort);
            [_webView loadRequest:[NSURLRequest requestWithURL:
                [NSURL URLWithString:[NSString stringWithFormat:@"http://localhost:%d", kMagentaAUDevServerPort]]]];
        } else {
            NSBundle* bundle = [NSBundle bundleForClass:[self class]];
            NSString* uiPath = [bundle pathForResource:@"index" ofType:@"html" inDirectory:@"jam_ui"];
            if (uiPath) {
                NSURL* url = [NSURL fileURLWithPath:uiPath];
                [_webView loadFileURL:url allowingReadAccessToURL:[url URLByDeletingLastPathComponent]];
            } else {
                NSLog(@"Jam: jam_ui/index.html not found in bundle");
            }
        }
    }
}

- (void)viewDidAppear {
    [super viewDidAppear];
    _isPlaying = NO;

    if (self.view.window) {
        self.view.window.minSize = NSMakeSize(850, 605);
    }

    if (_metricsTimer) [_metricsTimer invalidate];
    _metricsTicks = 0;
    _lastParams = [NSMutableDictionary dictionary];

    _metricsTimer = [NSTimer scheduledTimerWithTimeInterval:1.0/25.0
                                                    target:self
                                                  selector:@selector(updateMetrics)
                                                  userInfo:nil
                                                   repeats:YES];
}

- (void)viewDidDisappear {
    [super viewDidDisappear];
    if (_metricsTimer) { [_metricsTimer invalidate]; _metricsTimer = nil; }
    if (_webView) {
        [_webView.configuration.userContentController removeScriptMessageHandlerForName:@"auHost"];
        [_webView removeFromSuperview];
        _webView = nil;
    }
}

// ─── Metrics polling (25 Hz) ─────────────────────────────────────────────────

- (void)updateMetrics {
    MagentaAUAudioUnit* au = [self jamAU];
    if (au) [au pollOfflineState];
    RealtimeRunner* engine = [self engine];
    MagentaAUSharedState* shared = [au sharedState];
    if (!engine) return;

    _metricsTicks++;
    NSMutableDictionary* stateUpdate = [NSMutableDictionary dictionary];

    // Send MIDI active notes and audio levels every frame
    if (shared) {
        NSMutableArray* notes = [NSMutableArray array];
        for (int i = 0; i < 128; i++) {
            if (shared->midiNotes[i].load(std::memory_order_relaxed)) {
                [notes addObject:@(i)];
            }
        }
        stateUpdate[@"activeNotes"] = notes;

        float pL = 0.0f;
        float pR = 0.0f;
        shared->levelProcessor.read_and_reset_peaks(pL, pR);
        stateUpdate[@"audioLevels"] = @{
            @"left": @(pL),
            @"right": @(pR)
        };
    }

    // Metrics every 5th tick (~5 Hz)
    if (_metricsTicks >= 5) {
        _metricsTicks = 0;
        EngineMetrics m = engine->get_metrics();

        stateUpdate[@"metrics"] = @{
            @"frameMs": @(m.transformer_ms),
            @"bufferAvail": @(m.buffer_available),
            @"bufferCap": @(m.buffer_capacity),
            @"textEncoderStatus": @(engine->get_text_encoder_status()),
            @"droppedFrames": @(m.dropped_frames)
        };
    }

    // Params — send only changed values
    NSMutableDictionary* params = [NSMutableDictionary dictionary];
    int addresses[] = {0,1,3,4,5,6,7,8,9,32,39,46,48};
    for (int addr : addresses) {
        NSString* key = [MagentaSettings paramKeyForAddress:addr];
        if (!key) continue;
        float rawVal = [self readParamFromEngine:addr];
        NSNumber* val = [MagentaSettings paramIsBool:addr] ? @(rawVal > 0.5) : @(rawVal);
        NSNumber* lastVal = _lastParams[key];
        if (!lastVal || ![lastVal isEqualToNumber:val]) {
            params[key] = val;
            _lastParams[key] = val;
        }
    }
    // cfgnotesuser: the user's chosen note-adherence slider value, unaffected
    // by the solo-mode ramp that animates the engine's internal cfg_notes.
    if ([[self jamAU] cfgNotesSliderValue]) {
        NSNumber* sliderVal = @([[self jamAU] cfgNotesSliderValue]->load(std::memory_order_relaxed));
        NSNumber* lastSlider = _lastParams[@"cfgnotesuser"];
        if (!lastSlider || ![lastSlider isEqualToNumber:sliderVal]) {
            params[@"cfgnotesuser"] = sliderVal;
            _lastParams[@"cfgnotesuser"] = sliderVal;
        }
    }
    if (params.count > 0) stateUpdate[@"params"] = params;

    if (stateUpdate.count > 0) [self sendStateUpdate:stateUpdate];
}

// ─── State push to React ─────────────────────────────────────────────────────

- (void)sendStateUpdate:(NSDictionary*)state {
    if (!_webView) return;
    NSError* error = nil;
    NSData* jsonData = [NSJSONSerialization dataWithJSONObject:state options:0 error:&error];
    if (error) return;
    NSString* jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    NSString* script = [NSString stringWithFormat:@"if (window.updateState) { window.updateState(%@); }", jsonString];
    [_webView evaluateJavaScript:script completionHandler:nil];
}

- (void)sendPlayState:(BOOL)playing {
    _isPlaying = playing;
    [self sendStateUpdate:@{@"isPlaying": @(playing)}];
}

- (void)showReactSettings {
    [self sendStateUpdate:@{@"openSettings": @YES}];
}

- (void)connectToEngine {
    RealtimeRunner* engine = [self engine];
    if (!engine) return;

    NSMutableDictionary* initialParams = [NSMutableDictionary dictionary];
    int addresses[] = {0,1,3,4,5,6,7,8,9,32,39,46,48};
    for (int addr : addresses) {
        NSString* key = [MagentaSettings paramKeyForAddress:addr];
        if (!key) continue;
        float rawVal = [self readParamFromEngine:addr];
        NSNumber* val = [MagentaSettings paramIsBool:addr] ? @(rawVal > 0.5) : @(rawVal);
        initialParams[key] = val;
        _lastParams[key] = val;
    }

    // Include stable slider value for note adherence
    if ([[self jamAU] cfgNotesSliderValue]) {
        initialParams[@"cfgnotesuser"] = @([[self jamAU] cfgNotesSliderValue]->load(std::memory_order_relaxed));
    }

    NSMutableDictionary* state = [NSMutableDictionary dictionary];
    state[@"params"] = initialParams;
    state[@"isPlaying"] = @(_isPlaying);
    state[@"solomode"] = @([[self jamAU] soloMode] ? [[self jamAU] soloMode]->load(std::memory_order_relaxed) : NO);

    MagentaAUAudioUnit* jamAU = [self jamAU];
    if (jamAU.modelName.length > 0) {
        _modelName = jamAU.modelName;
    } else {
        NSString* savedName = [[NSUserDefaults standardUserDefaults] stringForKey:@"MGTAU_LoadedModelName"];
        if (!savedName) {
            savedName = [[NSUserDefaults standardUserDefaults] stringForKey:@"LoadedModelName"];
        }
        if (savedName.length > 0) _modelName = savedName;
    }
    if (_modelName) state[@"modelName"] = _modelName;

    // Restore saved prompt (always send, empty string if nothing saved)
    NSString* savedPrompt = [[NSUserDefaults standardUserDefaults] stringForKey:@"MGTAU_Prompt"];
    state[@"prompt"] = savedPrompt ?: @"";

    // Restore saved rocker index
    NSNumber* savedRockerIndex = [[NSUserDefaults standardUserDefaults] objectForKey:@"MGTAU_RockerIndex"];
    if (savedRockerIndex) state[@"savedRockerIndex"] = savedRockerIndex;

    // Restore saved prompt history
    NSArray* savedHistory = [[NSUserDefaults standardUserDefaults] arrayForKey:@"MGTAU_PromptHistory"];
    if (savedHistory) {
        state[@"savedPromptHistory"] = savedHistory;
        state[@"savedHistoryIndex"] = [[NSUserDefaults standardUserDefaults] objectForKey:@"MGTAU_HistoryIndex"] ?: @0;
    }

    state[@"computerKeyboardMidi"] = @([[NSUserDefaults standardUserDefaults] boolForKey:@"MGTAU_ComputerKeyboardMidi"]);

    // Restore user preset overrides
    NSDictionary* savedSolo = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"MGTAU_UserPresetsSolo"];
    NSDictionary* savedJam = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"MGTAU_UserPresetsJam"];
    if (savedSolo || savedJam) {
        NSMutableDictionary* presets = [NSMutableDictionary dictionary];
        if (savedSolo) presets[@"solo"] = savedSolo;
        if (savedJam) presets[@"jam"] = savedJam;
        state[@"savedUserPresets"] = presets;
    }

    NSString* savedPath = [[NSUserDefaults standardUserDefaults] stringForKey:@"DownloadFolderPath"];
    if (!savedPath) {
        savedPath = [[NSUserDefaults standardUserDefaults] stringForKey:@"MagentaRT_ModelFolderPath"];
    }
    if (!savedPath) {
        savedPath = [NSString stringWithUTF8String:magentart::paths::get_models_dir().c_str()];
    }
    state[@"downloadPath"] = savedPath;
    state[@"hostMode"] = @"auv3";
    state[@"computerKeyboardMidi"] = @YES;

    MGRTEnsureCustomResourcesPath();
    state[@"resourcesMissing"] = @(!MGRTSharedResourcesAvailable([self jamAU]));

    [self sendStateUpdate:state];
    [self handleListLocalModels];
    [self autoLoadSavedModelIfNeeded];
}

- (void)setComputerKeyboardMidiEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"MGTAU_ComputerKeyboardMidi"];
    [self sendStateUpdate:@{@"computerKeyboardMidi": @(enabled)}];
}

- (void)notifyModelLoaded:(NSString*)modelName {
    _modelName = modelName;

    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableDictionary* state = [NSMutableDictionary dictionary];
        state[@"modelName"] = modelName;

        NSMutableDictionary* params = [NSMutableDictionary dictionary];
        int addresses[] = {0,1,3,4,5,6,7,8,9,32,39,46,48};
        for (int addr : addresses) {
            NSString* key = [MagentaSettings paramKeyForAddress:addr];
            if (!key) continue;
            float rawVal = [self readParamFromEngine:addr];
            params[key] = [MagentaSettings paramIsBool:addr] ? @(rawVal > 0.5) : @(rawVal);
            self->_lastParams[key] = params[key];
        }
        if ([[self jamAU] cfgNotesSliderValue]) {
            params[@"cfgnotesuser"] = @([[self jamAU] cfgNotesSliderValue]->load(std::memory_order_relaxed));
        }
        state[@"params"] = params;

        // Re-apply current prompt to the freshly loaded model.
        // _currentPromptText may have been set by the frontend via textPrompts IPC
        // before the model finished loading, or from a previous saved prompt.
        if ([self engine]) {
            NSString* promptToUse = self->_currentPromptText.length > 0
                ? self->_currentPromptText
                : ([[NSUserDefaults standardUserDefaults] stringForKey:@"MGTAU_Prompt"] ?: @"");
            BOOL isSolo = [[self jamAU] soloMode] ? [[self jamAU] soloMode]->load(std::memory_order_relaxed) : YES;
            NSString* cleanPrompt = [promptToUse stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSString* engineText = @"";
            if (cleanPrompt.length == 0) {
                engineText = @"silence";
            } else {
                engineText = isSolo ? [NSString stringWithFormat:@"SOLO %@", cleanPrompt] : cleanPrompt;
            }
            std::vector<std::string> texts = {engineText.UTF8String, "", "", "", "", ""};
            std::vector<float> weights = {1.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
            [self engine]->set_text_prompts(texts, weights);
            [self engine]->set_blend_weights(weights.data(), (int)weights.size());
            self->_currentPromptText = promptToUse;
            state[@"prompt"] = promptToUse;
        }

        [self sendStateUpdate:state];
    });
}

// ─── Navigation delegate ─────────────────────────────────────────────────────

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    NSLog(@"Jam: WKWebView loaded");
}

// ─── Script message handler ──────────────────────────────────────────────────

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:@"auHost"] || ![message.body isKindOfClass:[NSDictionary class]]) return;
    NSDictionary* body = message.body;
    NSString* type = body[@"type"];

    if ([type isEqualToString:@"param"]) {
        NSNumber* indexValue = body[@"index"];
        NSNumber* paramValue = body[@"value"];
        if (indexValue && paramValue) {
            [self applyParamToEngine:indexValue.intValue value:paramValue.floatValue];
        }
    }
    else if ([type isEqualToString:@"setSoloMode"]) {
        NSNumber* valueVal = body[@"value"];
        if (valueVal) {
            BOOL solo = valueVal.boolValue;
            if ([[self jamAU] soloMode]) {
                [[self jamAU] soloMode]->store(solo, std::memory_order_relaxed);
            }
            [[NSUserDefaults standardUserDefaults] setBool:solo forKey:@"MGTAU_SoloMode"];
        }
    }
    else if ([type isEqualToString:@"textPrompts"]) {
        NSArray* promptsArray = body[@"value"];
        if ([promptsArray isKindOfClass:[NSArray class]] && [self engine]) {
            std::vector<std::string> texts;
            std::vector<float> weights;
            for (NSDictionary* p in promptsArray) {
                NSString* text = p[@"text"];
                NSNumber* weight = p[@"weight"];
                if ([text isKindOfClass:[NSString class]] && [weight isKindOfClass:[NSNumber class]]) {
                    NSString* trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (trimmed.length == 0 || [trimmed isEqualToString:@"SOLO"]) {
                        texts.push_back("silence");
                    } else {
                        texts.push_back(text.UTF8String);
                    }
                    weights.push_back(weight.floatValue);
                }
            }
            [self engine]->set_text_prompts(texts, weights);
            [self engine]->set_blend_weights(weights.data(), (int)weights.size());

            // Persist current prompt and history
            if (promptsArray.count > 0) {
                NSDictionary* p0 = promptsArray[0];
                NSString* prompt = p0[@"text"];
                if ([prompt isKindOfClass:[NSString class]]) {
                    if ([prompt hasPrefix:@"SOLO "]) {
                        prompt = [prompt substringFromIndex:5];
                    } else if ([prompt isEqualToString:@"SOLO"]) {
                        prompt = @"";
                    }
                    _currentPromptText = prompt;
                    MagentaAUAudioUnit* au = [self jamAU];
                    if (au) au.promptText = prompt;
                    [[NSUserDefaults standardUserDefaults] setObject:prompt forKey:@"MGTAU_Prompt"];
                }
            }
        }
    }
    else if ([type isEqualToString:@"loadModel"]) {
        [self handleLoadModel];
    }
    else if ([type isEqualToString:@"listLocalModels"]) {
        [self handleListLocalModels];
    }
    else if ([type isEqualToString:@"listRemoteModels"]) {
        [MagentaModelDownloader listRemoteModelsWithCompletion:^(NSArray<NSString *> *models, NSError *error) {
            if (error) {
                [self sendStateUpdate:@{@"remoteModelsError": error.localizedDescription}];
            } else {
                [self sendStateUpdate:@{@"remoteModels": models}];
            }
        }];
    }
    else if ([type isEqualToString:@"downloadModel"]) {
        NSString* name = body[@"name"];
        if (name) {
            [MagentaModelDownloader downloadModel:name progress:^(double progress, NSString *status) {
                [self sendStateUpdate:@{
                    @"downloadProgress": @{
                        @"status": @"downloading",
                        @"percent": @(progress),
                        @"text": status,
                        @"modelName": name
                    }
                }];
            } completion:^(BOOL success, NSError *error) {
                if (success) {
                    [self sendStateUpdate:@{
                        @"downloadProgress": @{
                            @"status": @"success",
                            @"percent": @(1.0),
                            @"text": @"Download Complete!",
                            @"modelName": name
                        }
                    }];
                    [self handleListLocalModels];
                } else {
                    [self sendStateUpdate:@{
                        @"downloadProgress": @{
                            @"status": @"error",
                            @"percent": @(0.0),
                            @"text": error.localizedDescription ?: @"Download Failed",
                            @"modelName": name
                        }
                    }];
                }
            }];
        }
    }
    else if ([type isEqualToString:@"selectDownloadFolder"]) {
        [self handleSelectDownloadFolder];
    }
    else if ([type isEqualToString:@"selectModel"]) {
        NSString* name = body[@"name"];
        if (name) {
            [self handleSelectModel:name];
        }
    }
    else if ([type isEqualToString:@"deleteModel"]) {
        NSString* name = body[@"name"];
        if (name) {
            [self handleDeleteModel:name];
        }
    }
    else if ([type isEqualToString:@"initResources"]) {
        NSString* modelName = body[@"modelName"];
        [self handleInitResources:modelName];
    }
    else if ([type isEqualToString:@"loadAudioPrompt"]) {
        NSNumber* indexVal = body[@"index"];
        [self handleLoadAudioPrompt:indexVal ? indexVal.intValue : 0];
    }
    else if ([type isEqualToString:@"loadAudioPromptData"]) {
        NSNumber* indexVal = body[@"index"];
        NSString* filename = body[@"filename"];
        NSString* base64 = body[@"data"];
        if (base64.length == 0) return;
        NSData* data = [[NSData alloc] initWithBase64EncodedString:base64
                                                          options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (!data) {
            [self finishAudioPromptLoad:nil index:(indexVal ? indexVal.intValue : 0) success:NO];
            return;
        }
        [self loadAudioPromptFromData:data
                             filename:filename
                                index:(indexVal ? indexVal.intValue : 0)];
    }
    else if ([type isEqualToString:@"clearAudioPrompt"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            RealtimeRunner* engine = [self engine];
            if (engine) {
                engine->set_audio_prompt_samples(0, "", nullptr, 0);
            }
            MagentaAUAudioUnit* au = [self jamAU];
            NSString* restored = self->_currentPromptText;
            if (restored.length == 0) {
                restored = [[NSUserDefaults standardUserDefaults] stringForKey:@"MGTAU_Prompt"] ?: @"";
            }
            if (au) {
                [au applyPromptTextToEngine:restored];
            }
            [self sendStateUpdate:@{
                @"prompt": restored ?: @"",
                @"isAudioPrompt": @NO,
            }];
        });
    }
    else if ([type isEqualToString:@"kbdNote"]) {
        NSNumber* noteVal = body[@"note"];
        NSNumber* onVal = body[@"on"];
        if (!noteVal || !onVal || ![self engine]) return;
        uint8_t note = (uint8_t)MIN(127, MAX(0, noteVal.intValue));
        BOOL on = onVal.boolValue;
        if (on) {
            [self engine]->set_note_on(note);
            if ([[self jamAU] sharedState]) [[self jamAU] sharedState]->noteOn(note);
        } else {
            [self engine]->set_note_off(note);
            if ([[self jamAU] sharedState]) [[self jamAU] sharedState]->noteOff(note);
        }
    }
    else if ([type isEqualToString:@"togglePlay"]) {
        NSNumber* valueVal = body[@"value"];
        BOOL target = valueVal ? valueVal.boolValue : !_isPlaying;
        MagentaAUAudioUnit* au = [self jamAU];
        if (au) {
            au.uiPlaying = target;
            RealtimeRunner* engine = [au engine];
            if (engine) engine->set_bypass(!target);
        }
        _isPlaying = target;
        [self sendStateUpdate:@{@"isPlaying": @(target)}];
    }
    else if ([type isEqualToString:@"openSettings"]) {
        [self sendStateUpdate:@{@"openSettings": @YES}];
    }
    else if ([type isEqualToString:@"savePromptHistory"]) {
        NSArray* history = body[@"history"];
        NSNumber* index = body[@"index"];
        if (history) [[NSUserDefaults standardUserDefaults] setObject:history forKey:@"MGTAU_PromptHistory"];
        if (index) [[NSUserDefaults standardUserDefaults] setObject:index forKey:@"MGTAU_HistoryIndex"];
    }
    else if ([type isEqualToString:@"saveUserPresets"]) {
        NSDictionary* solo = body[@"solo"];
        NSDictionary* jam = body[@"jam"];
        if ([solo isKindOfClass:[NSDictionary class]]) {
            [[NSUserDefaults standardUserDefaults] setObject:solo forKey:@"MGTAU_UserPresetsSolo"];
        }
        if ([jam isKindOfClass:[NSDictionary class]]) {
            [[NSUserDefaults standardUserDefaults] setObject:jam forKey:@"MGTAU_UserPresetsJam"];
        }
    }
    else if ([type isEqualToString:@"saveRockerIndex"]) {
        NSNumber* value = body[@"value"];
        if (value) {
            [[NSUserDefaults standardUserDefaults] setObject:value forKey:@"MGTAU_RockerIndex"];
        }
    }
    else if ([type isEqualToString:@"log"]) {
        NSString* val = body[@"value"];
        if (val) NSLog(@"MagentaAU UI: %@", val);
    }
    else if ([type isEqualToString:@"selectMidiSource"]) {
        // In AUv3 mode MIDI comes from the DAW host; computer keyboard remains available via kbdNote.
        [self sendStateUpdate:@{@"computerKeyboardMidi": @YES}];
    }
    else if ([type isEqualToString:@"uiReady"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self connectToEngine];
        });
    }
}

// ─── Model loading (shared core) ─────────────────────────────────────────────

- (NSString*)mlxfnPathForModelAtURL:(NSURL*)modelURL {
    if (!modelURL) return nil;
    NSString* path = modelURL.path;
    BOOL isDir = NO;
    [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];

    if ([path hasSuffix:@".mlxfn"]) {
        return path;
    }
    if (isDir) {
        std::string dirPathStr = path.UTF8String;
        std::string foundMlxfn = magentart::paths::find_mlxfn_in_dir(dirPathStr);
        if (!foundMlxfn.empty()) {
            return [NSString stringWithUTF8String:foundMlxfn.c_str()];
        }
    }
    return nil;
}

- (void)saveLoadedModelBookmarkForURL:(NSURL*)modelURL modelName:(NSString*)modelName {
    if (!modelURL || !modelName) return;
    MagentaAUAudioUnit* au = [self jamAU];
    if (!au) return;

    NSError* bmErr = nil;
    NSData* modelBookmark = [modelURL bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope
                               includingResourceValuesForKeys:nil
                                                relativeToURL:nil
                                                        error:&bmErr];
    if (modelBookmark) {
        au.modelBookmark = modelBookmark;
        au.modelName = modelName;
        NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
        [defaults setObject:modelBookmark forKey:@"LoadedModelBookmark"];
        [defaults setObject:modelName forKey:@"MGTAU_LoadedModelName"];
        [defaults setObject:modelName forKey:@"LoadedModelName"];
    } else if (bmErr) {
        NSLog(@"MagentaAU_AU: Failed to create model bookmark: %@", bmErr.localizedDescription);
    }
}

- (BOOL)loadModelAtPath:(NSString*)mlxfnPath {
    RealtimeRunner* engine = [self engine];
    if (!engine || !mlxfnPath) return NO;

    NSLog(@"MagentaAU: Loading model from %@", mlxfnPath);
    BOOL success = engine->load_model(mlxfnPath.UTF8String);

    if (success) {
        _modelName = mlxfnPath.lastPathComponent;

        // Auto-load corpus
        NSString* parentDir = [mlxfnPath stringByDeletingLastPathComponent];
        NSString* corpusPath = [parentDir stringByAppendingPathComponent:@"corpus.safetensors"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:corpusPath]) {
            engine->load_pca_file(corpusPath.UTF8String);
        }

        // Re-apply prompt to engine with proper SOLO prefix
        NSString* savedPrompt = [[NSUserDefaults standardUserDefaults] stringForKey:@"MGTAU_Prompt"];
        NSString* promptToUse = _currentPromptText.length > 0 ? _currentPromptText
                                : (savedPrompt.length > 0 ? savedPrompt : @"");
        _currentPromptText = promptToUse;
        BOOL isSolo = [[self jamAU] soloMode] ? [[self jamAU] soloMode]->load(std::memory_order_relaxed) : YES;
        NSString* cleanPrompt = [promptToUse stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString* engineText = @"";
        if (cleanPrompt.length == 0) {
            engineText = @"silence";
        } else {
            engineText = isSolo ? [NSString stringWithFormat:@"SOLO %@", cleanPrompt] : cleanPrompt;
        }
        std::vector<std::string> texts = {engineText.UTF8String, "", "", "", "", ""};
        std::vector<float> weights = {1.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
        engine->set_text_prompts(texts, weights);
        engine->set_blend_weights(weights.data(), (int)weights.size());

        [self notifyModelLoaded:mlxfnPath.lastPathComponent];
        [[NSUserDefaults standardUserDefaults] setObject:mlxfnPath forKey:@"MGTAU_ModelPath"];
        [self sendStateUpdate:@{@"resourcesMissing": @NO}];
    } else {
        [self sendStateUpdate:@{@"modelName": [NSString stringWithFormat:@"Failed: %@", mlxfnPath.lastPathComponent]}];
    }
    return success;
}

- (void)autoLoadSavedModelIfNeeded {
    MagentaAUAudioUnit* au = [self jamAU];
    RealtimeRunner* engine = [self engine];
    if (!au || !engine || engine->is_loaded()) return;

    if (au.modelBookmark) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            BOOL stale = NO;
            NSError* error = nil;
            NSURL* url = [NSURL URLByResolvingBookmarkData:au.modelBookmark
                                                   options:NSURLBookmarkResolutionWithoutUI | NSURLBookmarkResolutionWithSecurityScope
                                             relativeToURL:nil
                                       bookmarkDataIsStale:&stale
                                                     error:&error];
            if (url && [url startAccessingSecurityScopedResource]) {
                NSString* mlxfnPath = [self mlxfnPathForModelAtURL:url];
                if (mlxfnPath && [self loadModelAtPath:mlxfnPath]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self saveLoadedModelBookmarkForURL:url modelName:au.modelName ?: mlxfnPath.lastPathComponent];
                    });
                }
                [url stopAccessingSecurityScopedResource];
                return;
            }
            NSLog(@"MagentaAU_AU: Failed to resolve AU model bookmark: %@", error);
        });
        return;
    }

    NSData* savedBookmark = [[NSUserDefaults standardUserDefaults] objectForKey:@"LoadedModelBookmark"];
    if (savedBookmark) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            BOOL stale = NO;
            NSError* error = nil;
            NSURL* url = [NSURL URLByResolvingBookmarkData:savedBookmark
                                                   options:NSURLBookmarkResolutionWithoutUI | NSURLBookmarkResolutionWithSecurityScope
                                             relativeToURL:nil
                                       bookmarkDataIsStale:&stale
                                                     error:&error];
            if (url && [url startAccessingSecurityScopedResource]) {
                NSString* mlxfnPath = [self mlxfnPathForModelAtURL:url];
                if (mlxfnPath && [self loadModelAtPath:mlxfnPath]) {
                    NSString* savedModelName = [[NSUserDefaults standardUserDefaults] stringForKey:@"MGTAU_LoadedModelName"];
                    if (!savedModelName) {
                        savedModelName = [[NSUserDefaults standardUserDefaults] stringForKey:@"LoadedModelName"];
                    }
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self saveLoadedModelBookmarkForURL:url
                                                  modelName:savedModelName ?: mlxfnPath.lastPathComponent];
                    });
                }
                [url stopAccessingSecurityScopedResource];
                return;
            }
            NSLog(@"MagentaAU_AU: Failed to resolve saved model bookmark: %@", error);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self tryAutoLoadFromModelsDirectory];
            });
        });
        return;
    }

    [self tryAutoLoadFromModelsDirectory];
}

- (void)tryAutoLoadFromModelsDirectory {
    RealtimeRunner* engine = [self engine];
    if (!engine || engine->is_loaded()) return;

    MGRTEnsureCustomResourcesPath();

    BOOL accessGranted = NO;
    NSURL* scopedBase = nil;
    NSURL* modelsDir = MGRTResolveModelsDirectory(&accessGranted, &scopedBase);
    NSArray<NSString*>* modelFiles = [MagentaModelManager listLocalModelsInDirectory:modelsDir];
    if (modelFiles.count == 0) {
        if (accessGranted && scopedBase) [scopedBase stopAccessingSecurityScopedResource];
        NSLog(@"MagentaAU: tryAutoLoad — no models found (searched %@)", modelsDir.path);
        return;
    }

    NSString* preferred = MGRTPreferredModelName(modelFiles);
    NSURL* modelURL = [modelsDir URLByAppendingPathComponent:preferred];
    NSString* mlxfnPath = [self mlxfnPathForModelAtURL:modelURL];
    if (mlxfnPath && [self loadModelAtPath:mlxfnPath]) {
        [self saveLoadedModelBookmarkForURL:modelURL modelName:preferred];
    }

    if (accessGranted && scopedBase) {
        [scopedBase stopAccessingSecurityScopedResource];
    }
}

- (void)handleLoadModel {
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    [panel setCanChooseFiles:YES];
    [panel setCanChooseDirectories:YES];
    [panel setMessage:@"Select the directory containing your model, or the .mlxfn file."];

    void (^completionBlock)(NSModalResponse) = ^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSURL* url = [panel URL];
        if (!url) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            NSString* path = url.path;
            BOOL accessed = [url startAccessingSecurityScopedResource];

            NSString* mlxfnPath = [self mlxfnPathForModelAtURL:url];
            if (!mlxfnPath) {
                if (accessed) [url stopAccessingSecurityScopedResource];
                [self sendStateUpdate:@{@"modelName": @"No .mlxfn found"}];
                return;
            }

            if ([self loadModelAtPath:mlxfnPath]) {
                [self saveLoadedModelBookmarkForURL:url modelName:mlxfnPath.lastPathComponent];
            }
            if (accessed) [url stopAccessingSecurityScopedResource];
        });
    };

    if (self.view.window) {
        [panel beginSheetModalForWindow:self.view.window completionHandler:completionBlock];
    } else {
        [panel beginWithCompletionHandler:completionBlock];
    }
}

// ─── Audio prompt loading ────────────────────────────────────────────────────

- (void)finishAudioPromptLoad:(NSString*)displayName index:(int)index success:(BOOL)success {
    RealtimeRunner* engine = [self engine];
    if (success && engine) {
        float weights[6] = {1.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
        engine->set_blend_weights(weights, 6);
    }
    [self sendStateUpdate:@{
        @"prompt": success ? (displayName ?: @"Audio reference") : @"Error: Audio load failed",
        @"isAudioPrompt": @(success),
    }];
}

- (BOOL)decodeAudioPromptAtURL:(NSURL*)url
                           index:(int)index
                        filename:(NSString*)fallbackName {
    RealtimeRunner* engine = [self engine];
    if (!engine || !url) return NO;

    NSString* displayName = fallbackName.length ? fallbackName : url.lastPathComponent;
    BOOL readSuccess = NO;

    ExtAudioFileRef extFile = nullptr;
    OSStatus status = ExtAudioFileOpenURL((__bridge CFURLRef)url, &extFile);
    if (status == noErr && extFile) {
        AudioStreamBasicDescription clientFormat = {};
        clientFormat.mSampleRate = 16000.0;
        clientFormat.mFormatID = kAudioFormatLinearPCM;
        clientFormat.mFormatFlags = kAudioFormatFlagIsFloat;
        clientFormat.mBitsPerChannel = 32;
        clientFormat.mChannelsPerFrame = 1;
        clientFormat.mBytesPerFrame = 4;
        clientFormat.mFramesPerPacket = 1;
        clientFormat.mBytesPerPacket = 4;

        status = ExtAudioFileSetProperty(extFile, kExtAudioFileProperty_ClientDataFormat,
                                          sizeof(clientFormat), &clientFormat);
        if (status == noErr) {
            constexpr int maxFrames = 160000; // 10s @ 16 kHz mono
            std::vector<float> samples(maxFrames, 0.0f);
            AudioBufferList bufferList = {};
            bufferList.mNumberBuffers = 1;
            bufferList.mBuffers[0].mNumberChannels = 1;
            bufferList.mBuffers[0].mDataByteSize = maxFrames * sizeof(float);
            bufferList.mBuffers[0].mData = samples.data();

            UInt32 framesToRead = maxFrames;
            status = ExtAudioFileRead(extFile, &framesToRead, &bufferList);
            if (status == noErr && framesToRead > 0) {
                if (framesToRead < (UInt32)maxFrames) {
                    for (UInt32 i = framesToRead; i < (UInt32)maxFrames; ++i) {
                        samples[i] = samples[i % framesToRead];
                    }
                }
                engine->set_audio_prompt_samples(index, displayName.UTF8String,
                                                 samples.data(), maxFrames);
                readSuccess = YES;
            }
        }
        ExtAudioFileDispose(extFile);
    }

    if (!readSuccess) {
        NSLog(@"MagentaAU_AU: failed to decode audio reference at %@", url.path);
    }
    return readSuccess;
}

- (void)loadAudioPromptFromURL:(NSURL*)url index:(int)index accessGranted:(BOOL)accessGranted {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString* displayName = url.lastPathComponent;
        BOOL success = [self decodeAudioPromptAtURL:url
                                              index:index
                                           filename:displayName];
        if (accessGranted) {
            [url stopAccessingSecurityScopedResource];
        }
        [self finishAudioPromptLoad:displayName index:index success:success];
    });
}

- (void)loadAudioPromptFromData:(NSData*)data filename:(NSString*)filename index:(int)index {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString* safeName = filename.length ? filename : @"reference.wav";
        NSString* tempPath = [NSTemporaryDirectory()
            stringByAppendingPathComponent:[NSString stringWithFormat:@"jam-ref-%@", safeName]];
        if (![data writeToFile:tempPath atomically:YES]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self finishAudioPromptLoad:safeName index:index success:NO];
            });
            return;
        }

        NSURL* url = [NSURL fileURLWithPath:tempPath];
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL success = [self decodeAudioPromptAtURL:url
                                                  index:index
                                               filename:safeName];
            [self finishAudioPromptLoad:safeName index:index success:success];
        });
    });
}

- (void)loadAudioPromptFileAtPath:(NSString*)path index:(int)index {
    if (!path) return;
    [self loadAudioPromptFromURL:[NSURL fileURLWithPath:path] index:index accessGranted:NO];
}

- (void)handleLoadAudioPrompt:(int)index {
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    [panel setCanChooseFiles:YES];
    [panel setCanChooseDirectories:NO];
    [panel setAllowsMultipleSelection:NO];
    [panel setAllowedContentTypes:@[
        UTTypeAudio,
        [UTType typeWithFilenameExtension:@"wav"],
        [UTType typeWithFilenameExtension:@"mp3"],
        [UTType typeWithFilenameExtension:@"m4a"],
        [UTType typeWithFilenameExtension:@"aiff"],
        [UTType typeWithFilenameExtension:@"aif"],
    ]];
    [panel setMessage:@"Select a WAV or MP3 file to use as an audio reference."];

    void (^completionBlock)(NSModalResponse) = ^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSURL* url = [panel URL];
        if (!url) return;

        BOOL accessed = [url startAccessingSecurityScopedResource];
        [self loadAudioPromptFromURL:url index:index accessGranted:accessed];
    };

    if (self.view.window) {
        [panel beginSheetModalForWindow:self.view.window completionHandler:completionBlock];
    } else {
        [panel beginWithCompletionHandler:completionBlock];
    }
}

- (void)handleSelectDownloadFolder {
    [MagentaModelManager selectDownloadFolderWithParentWindow:self.view.window
                                                  completion:^(NSString *selectedPath, NSData *bookmarkData, NSError *error) {
        if (selectedPath && bookmarkData) {
            dispatch_async(dispatch_get_main_queue(), ^{
                MGRTSaveModelsFolderBookmark(selectedPath, bookmarkData);

                NSString *resourcesPathToLoad = MGRTSandboxAwareResourcesPath(selectedPath);

                RealtimeRunner* engine = [self engine];
                if (engine) {
                    if (!engine->init_assets(resourcesPathToLoad.UTF8String)) {
                        NSLog(@"MagentaAU_AU: Failed to initialize assets from path: %@", resourcesPathToLoad);
                    } else {
                        NSLog(@"MagentaAU_AU: Successfully initialized assets from path: %@", resourcesPathToLoad);
                        [[NSUserDefaults standardUserDefaults] setObject:resourcesPathToLoad forKey:@"MagentaRT_CustomResourcesPath"];
                    }
                }

                MGRTEnsureCustomResourcesPath();
                MagentaAUAudioUnit* au = [self jamAU];
                [self sendStateUpdate:@{
                    @"downloadPath": selectedPath,
                    @"resourcesMissing": @(!MGRTSharedResourcesAvailable(au))
                }];

                [self handleListLocalModels];

                BOOL accessGranted = NO;
                NSURL* scopedBase = nil;
                NSURL* modelsDir = MGRTResolveModelsDirectory(&accessGranted, &scopedBase);
                NSArray<NSString *> *modelFiles = [MagentaModelManager listLocalModelsInDirectory:modelsDir];
                if (accessGranted && scopedBase) {
                    [scopedBase stopAccessingSecurityScopedResource];
                }
                if (modelFiles.count > 0) {
                    NSString* preferred = MGRTPreferredModelName(modelFiles);
                    [self handleSelectModel:preferred];
                } else {
                    NSLog(@"MagentaAU: no models found under %@ (effective: %@)", selectedPath, modelsDir.path);
                }
            });
        } else if (error) {
            NSLog(@"MagentaAU_AU: Failed to create folder bookmark: %@", error.localizedDescription);
        }
    }];
}

- (void)handleListLocalModels {
    BOOL accessGranted = NO;
    NSURL* scopedBase = nil;
    NSURL* modelsDir = MGRTResolveModelsDirectory(&accessGranted, &scopedBase);

    [[NSFileManager defaultManager] createDirectoryAtURL:modelsDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSArray<NSString *> *modelFiles = [MagentaModelManager listLocalModelsInDirectory:modelsDir];
    NSLog(@"MagentaAU_AU: listLocalModels at %@ -> %lu models", modelsDir.path, (unsigned long)modelFiles.count);

    if (accessGranted && scopedBase) {
        [scopedBase stopAccessingSecurityScopedResource];
    }

    NSMutableDictionary* update = [NSMutableDictionary dictionaryWithObject:modelFiles forKey:@"localModels"];
    if (modelFiles.count > 0 && MGRTSharedResourcesAvailable([self jamAU])) {
        update[@"resourcesMissing"] = @NO;
    }
    [self sendStateUpdate:update];
}

- (void)handleSelectModel:(NSString*)modelName {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self engine]) return;

        BOOL accessGranted = NO;
        NSURL* scopedBase = nil;
        NSURL* modelsDir = MGRTResolveModelsDirectory(&accessGranted, &scopedBase);

        NSURL* modelURL = [modelsDir URLByAppendingPathComponent:modelName];
        NSString* mlxfnPath = [self mlxfnPathForModelAtURL:modelURL];

        if (!mlxfnPath) {
            [self sendStateUpdate:@{@"modelName": @"No .mlxfn found"}];
            if (accessGranted && scopedBase) [scopedBase stopAccessingSecurityScopedResource];
            return;
        }

        if ([self loadModelAtPath:mlxfnPath]) {
            [self saveLoadedModelBookmarkForURL:modelURL modelName:modelName];
        }

        if (accessGranted && scopedBase) {
            [scopedBase stopAccessingSecurityScopedResource];
        }
    });
}

- (void)handleDeleteModel:(NSString *)modelName {
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL accessGranted = NO;
        NSURL* scopedBase = nil;
        NSURL* modelsDir = MGRTResolveModelsDirectory(&accessGranted, &scopedBase);

        NSURL* modelURL = [modelsDir URLByAppendingPathComponent:modelName];
        NSString* path = modelURL.path;

        NSError *error = nil;
        [[NSFileManager defaultManager] removeItemAtPath:path error:&error];
        if (error) {
            NSLog(@"Jam: Failed to delete model %@: %@", modelName, error.localizedDescription);
        } else {
            NSLog(@"Jam: Successfully deleted model %@", modelName);
            [self handleListLocalModels];
        }

        if (accessGranted && scopedBase) {
            [scopedBase stopAccessingSecurityScopedResource];
        }
    });
}

- (void)handleInitResources:(NSString *)modelName {
    BOOL hasModel = modelName && modelName.length > 0;

    [MagentaModelDownloader initializeSharedResourcesWithProgress:^(double progress, NSString *status) {
        double scaledPercent = hasModel ? progress * 0.5 : progress;
        NSString *statusWithProgress = [NSString stringWithFormat:@"[1/2] Shared assets: %@", status];
        if (!hasModel) statusWithProgress = status;

        [self sendStateUpdate:@{
            @"resourcesProgress": @{
                @"status": @"downloading",
                @"percent": @(scaledPercent),
                @"text": statusWithProgress
            }
        }];
    } completion:^(BOOL success, NSError *error) {
        if (!success) {
            [self sendStateUpdate:@{
                @"resourcesProgress": @{
                    @"status": @"error",
                    @"percent": @(0.0),
                    @"text": error.localizedDescription ?: @"Initialization Failed"
                }
            }];
            return;
        }

        if (hasModel) {
            // Start downloading the selected model
            [MagentaModelDownloader downloadModel:modelName progress:^(double progress, NSString *status) {
                double scaledPercent = 0.5 + (progress * 0.5);
                [self sendStateUpdate:@{
                    @"resourcesProgress": @{
                        @"status": @"downloading",
                        @"percent": @(scaledPercent),
                        @"text": [NSString stringWithFormat:@"[2/2] Model: %@", status]
                    }
                }];
            } completion:^(BOOL success, NSError *error) {
                if (success) {
                    // Re-initialize the C++ engine assets with the newly downloaded resources!
                    std::string resources = magentart::paths::get_resources_dir();
                    if (![self engine]->init_assets(resources.c_str())) {
                        NSLog(@"Jam: Failed to re-initialize C++ assets after onboarding download");
                    } else {
                        NSLog(@"Jam: Successfully initialized C++ assets after onboarding download");
                    }

                    [self sendStateUpdate:@{
                        @"resourcesProgress": @{
                            @"status": @"success",
                            @"percent": @(1.0),
                            @"text": @"Onboarding Completed!"
                        },
                        @"resourcesMissing": @NO
                    }];
                    // Re-list local models so it immediately appears in local list
                    [self handleListLocalModels];

                    // Programmatically select and load the newly downloaded model into the C++ engine
                    [self handleSelectModel:modelName];
                } else {
                    [self sendStateUpdate:@{
                        @"resourcesProgress": @{
                            @"status": @"error",
                            @"percent": @(0.5),
                            @"text": error.localizedDescription ?: @"Model download failed"
                        }
                    }];
                }
            }];
        } else {
            // Finished resources download only
            // Re-initialize the C++ engine assets with the newly downloaded resources!
            std::string resources = magentart::paths::get_resources_dir();
            if (![self engine]->init_assets(resources.c_str())) {
                NSLog(@"Jam: Failed to re-initialize C++ assets after onboarding download");
            } else {
                NSLog(@"Jam: Successfully initialized C++ assets after onboarding download");
            }

            [self sendStateUpdate:@{
                @"resourcesProgress": @{
                    @"status": @"success",
                    @"percent": @(1.0),
                    @"text": @"Initialization Completed!"
                },
                @"resourcesMissing": @NO
            }];
        }
    }];
}

- (void)dealloc {
    [_metricsTimer invalidate];
}

// ─── MIDI management (AUv3: host provides MIDI; UI uses computer keyboard) ───

- (void)handleMIDIStructureChanged {
    [self sendStateUpdate:@{@"midiSources": @[], @"hostMode": @"auv3"}];
}

- (void)selectMidiInput:(uint32_t)selectedEndpoint {
    (void)selectedEndpoint;
    [self setComputerKeyboardMidiEnabled:YES];
}

@end

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Same names and selectors as include/cef_application_mac.h. Declared here (and that header
// deliberately NOT imported anywhere) so a Swift NSApplication subclass can adopt them;
// Chromium finds them by protocol name at runtime.
NS_SWIFT_UI_ACTOR
@protocol CrAppProtocol
- (BOOL)isHandlingSendEvent;
@end

NS_SWIFT_UI_ACTOR
@protocol CrAppControlProtocol <CrAppProtocol>
- (void)setHandlingSendEvent:(BOOL)handlingSendEvent;
@end

NS_SWIFT_UI_ACTOR
@protocol CefAppProtocol <CrAppControlProtocol>
@end

typedef void (^BSExceptionSink)(NSException *exception) NS_SWIFT_SENDABLE;

/// The application class. AppKit's run loop calls `reportException:` for an exception thrown out
/// of an event handler, and Chromium makes that fatal. An exception that unwound out of a Swift
/// concurrency job leaves the thread's executor tracking pointing at a dead frame, so a Swift
/// override of this method faults in its main-actor check before it can log anything. The
/// override here is Objective-C, so no executor check runs; the sink is a nonisolated closure.
/// It logs, then `super` ends the process: the exception is never swallowed.
@interface BSApplication : NSApplication
@property(class, nonatomic, copy, nullable) BSExceptionSink onReportException;
@end

/// Thin ObjC facade over the CEF C++ API. Every method must be called on the main thread,
/// which is also CEF's UI thread on macOS. Callbacks arrive on the main thread too.
NS_SWIFT_UI_ACTOR
@interface BSCef : NSObject

+ (BOOL)loadFrameworkInMain;

/// Sandbox on. `rootCachePath` is both the root cache and the (persistent) profile. Chromium
/// logs to `logFile` at warning level, or at verbose level when `verbose` is YES.
+ (BOOL)initializeWithRootCachePath:(NSString *)rootCachePath
                            logFile:(NSString *)logFile
                            verbose:(BOOL)verbose;

@property(class, nonatomic, copy, nullable) void (^onContextInitialized)(void);
@property(class, nonatomic, copy, nullable) void (^onAddressChange)(int browserId, NSString *url);
@property(class, nonatomic, copy, nullable) void (^onTitleChange)(int browserId, NSString *title);
@property(class, nonatomic, copy, nullable) void (^onLoadingStateChange)
    (int browserId, BOOL loading, BOOL canGoBack, BOOL canGoForward);
/// A main-frame navigation committed (a reload and a failed load's error page included); the
/// page's DevTools document already belongs to the new document.
@property(class, nonatomic, copy, nullable) void (^onDocumentCommitted)(int browserId);
/// Find-in-page progress: `count` matches, `activeOrdinal` is the 1-based current one (0 if none).
@property(class, nonatomic, copy, nullable) void (^onFindResult)
    (int browserId, int count, int activeOrdinal);
/// Called for every key event bound for a page. Return YES to keep the page from seeing it (the
/// app's menu owns that key equivalent). `perform` is YES only for the first event of a
/// keystroke, so the menu action runs once; the matching key-up is claimed without performing.
@property(class, nonatomic, copy, nullable) BOOL (^claimKeyEvent)(NSEvent *event, BOOL perform);
@property(class, nonatomic, copy, nullable) void (^onBrowserClosed)(int browserId);
/// A main-frame load failed: Chromium's net error code and its name (e.g. ERR_CONNECTION_REFUSED).
@property(class, nonatomic, copy, nullable) void (^onLoadError)
    (int browserId, int errorCode, NSString *errorText, NSString *failedUrl);
/// A page asked for a new window (target=_blank, window.open, a ⌘-click). Return the view the new
/// browser should be a child of, or nil to refuse it. The browser is created with the opener in
/// the same process, so window.opener keeps working.
@property(class, nonatomic, copy, nullable) NSView *_Nullable (^onBeforePopup)
    (int openerBrowserId, NSString *url, BOOL background);
/// A link was opened for a new tab (⌘-click, middle click) rather than as a script popup. The
/// request is always cancelled in the source page; the app opens the address itself.
@property(class, nonatomic, copy, nullable) void (^onOpenURLInNewTab)
    (int openerBrowserId, NSString *url, BOOL background);
/// The popup browser exists and lives in `parent`, a view an earlier onBeforePopup returned.
@property(class, nonatomic, copy, nullable) void (^onPopupCreated)(int browserId, NSView *parent);
/// Creation failed after onBeforePopup accepted it; `parent` can be discarded.
@property(class, nonatomic, copy, nullable) void (^onPopupAborted)(NSView *parent);
/// Tab ran past the page's last focusable element (`next` YES) or back before its first (NO): the
/// page no longer wants the key, so focus belongs to the next or previous view of the window.
@property(class, nonatomic, copy, nullable) void (^onTakeFocus)(int browserId, BOOL next);
/// Every DevTools message from a browser (method results and events), as UTF-8 JSON. Taken from
/// OnDevToolsMessage: CEF never calls OnDevToolsMethodResult for some browser-handled methods
/// (Page.getNavigationHistory), so the callback pair cannot be relied on.
@property(class, nonatomic, copy, nullable) void (^onDevToolsMessage)(int browserId, NSData *json);

/// Creates a windowed Alloy browser as a child of `parent`. Returns the browser id, or 0.
+ (int)createBrowserInView:(NSView *)parent url:(NSString *)url;
+ (void)closeBrowser:(int)browserId;
+ (void)focusBrowser:(int)browserId;
+ (void)loadURL:(NSString *)url inBrowser:(int)browserId;
+ (void)goBackInBrowser:(int)browserId;
+ (void)goForwardInBrowser:(int)browserId;
+ (void)reloadBrowser:(int)browserId;
/// `findNext` NO starts a new search for `text`; YES steps to the next or previous match.
+ (void)find:(NSString *)text forward:(BOOL)forward findNext:(BOOL)findNext inBrowser:(int)browserId;
+ (void)stopFindingInBrowser:(int)browserId;
/// Runs undo, redo, cut, copy, paste or selectAll in the browser's focused frame.
/// The visible entry's connection: 0 unknown, 1 secure, 2 certificate error, 3 not encrypted.
+ (int)sslStateInBrowser:(int)browserId;
+ (void)editCommand:(NSString *)command inBrowser:(int)browserId;

/// `json` is a whole DevTools message: {"id":N,"method":...,"params":{...}}. NO if the browser is gone.
+ (BOOL)sendDevToolsMessage:(NSString *)json toBrowser:(int)browserId;

/// CefRunMessageLoop(): runs [NSApp run] with Chromium's pump installed.
+ (void)runMessageLoop;
+ (void)quitMessageLoop;
+ (void)shutdown;

@end

NS_ASSUME_NONNULL_END

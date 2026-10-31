#import "CEFBridge.h"

#include <crt_externs.h>

#include <deque>
#include <map>

#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"

static void (^gOnContextInitialized)(void);
static void (^gOnAddressChange)(int, NSString *);
static void (^gOnTitleChange)(int, NSString *);
static void (^gOnLoadingStateChange)(int, BOOL, BOOL, BOOL);
static void (^gOnDocumentCommitted)(int);
static void (^gOnFindResult)(int, int, int);
static BOOL (^gClaimKeyEvent)(NSEvent *, BOOL);
static void (^gOnBrowserClosed)(int);
static void (^gOnLoadError)(int, int, NSString *, NSString *);
static void (^gOnDevToolsMessage)(int, NSData *);
static NSView *(^gOnBeforePopup)(int, NSString *, BOOL);
static void (^gOnOpenURLInNewTab)(int, NSString *, BOOL);
static void (^gOnPopupCreated)(int, NSView *);
static void (^gOnPopupAborted)(NSView *);
static void (^gOnTakeFocus)(int, BOOL);

static CefScopedLibraryLoader *gLoader;

namespace {

int BrowserHostedIn(NSView *view);
void SyncRenderer(int browserId);

// Chromium sizes the render widget view from a cached rect and can apply a stale one after the
// host view was resized (about 30 ms later; measured when a resize follows the browser's
// creation). The renderer then stays at the old size, so the view must always fill its parent,
// and the renderer is told again once it does. The correction runs a turn later: Chromium's own
// setFrame is still on the stack when the notification is posted and would overwrite it.
void KeepFillingParent() {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    [NSNotificationCenter.defaultCenter
        addObserverForName:NSViewFrameDidChangeNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
                  NSView *view = note.object;
                  NSView *parent = view.superview;
                  if (!parent || NSEqualRects(view.frame, parent.bounds)) return;
                  int id = BrowserHostedIn(view);
                  if (!id) return;
                  dispatch_async(dispatch_get_main_queue(), ^{
                    if (view.superview != parent || NSEqualRects(view.frame, parent.bounds)) return;
                    view.frame = parent.bounds;
                    SyncRenderer(id);
                  });
                }];
  });
}

NSString *ToNS(const CefString &s) {
  return [NSString stringWithUTF8String:s.ToString().c_str()] ?: @"";
}

class BSApp : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

  void OnBeforeCommandLineProcessing(const CefString &process_type,
                                     CefRefPtr<CefCommandLine> command_line) override {
    if (process_type.empty()) {
      // Avoids the "Chromium Safe Storage" keychain prompt.
      command_line->AppendSwitch("use-mock-keychain");
      // An agent keeps working while the window is behind others; an occluded WebContents is
      // hidden, which stops rendering and drops input to any document loaded after the first.
      // MacAppCodeSignClone copies the whole bundle (~335 MB) into the temp dir on every launch
      // and only a clean exit removes it, so a crash or kill leaked it. The copy only matters
      // for an app updated in place while it runs.
      command_line->AppendSwitchWithValue("disable-features",
                                          "WebContentsOcclusion,MacAppCodeSignClone");
      command_line->AppendSwitch("disable-backgrounding-occluded-windows");
    }
  }

  void OnContextInitialized() override {
    if (gOnContextInitialized) gOnContextInitialized();
  }

 private:
  IMPLEMENT_REFCOUNTING(BSApp);
};

NSData *ToData(const void *bytes, size_t size) {
  return bytes ? [NSData dataWithBytes:bytes length:size] : [NSData data];
}

class BSObserver : public CefDevToolsMessageObserver {
 public:
  bool OnDevToolsMessage(CefRefPtr<CefBrowser> browser, const void *message, size_t size) override {
    if (gOnDevToolsMessage) gOnDevToolsMessage(browser->GetIdentifier(), ToData(message, size));
    return true;
  }

 private:
  IMPLEMENT_REFCOUNTING(BSObserver);
};

// Destroying the registration unregisters the observer, so it lives as long as the browser.
struct BrowserEntry {
  CefRefPtr<CefBrowser> browser;
  CefRefPtr<CefRegistration> devtools;
};
std::map<int, BrowserEntry> gBrowsers;

// The browser a view belongs to when it is one of the two levels under the host view:
// WebContentsViewCocoa and the render widget view.
int BrowserHostedIn(NSView *view) {
  for (auto &entry : gBrowsers) {
    NSView *host = (__bridge NSView *)entry.second.browser->GetHost()->GetWindowHandle();
    if (view.superview == host || view.superview.superview == host) return entry.first;
  }
  return 0;
}

// Clearing a device-metrics override that was never set makes the host synchronise the renderer
// with the view's current size; the id is far above the ones CDPChannel hands out, so the reply
// is ignored.
void SyncRenderer(int browserId) {
  auto it = gBrowsers.find(browserId);
  if (it == gBrowsers.end()) return;
  static const char kClear[] =
      "{\"id\":1073741824,\"method\":\"Emulation.clearDeviceMetricsOverride\"}";
  it->second.browser->GetHost()->SendDevToolsMessage(kClear, sizeof(kClear) - 1);
}

// Parent views handed to popups that are not created yet, per opener, in request order.
// Entries leave on creation or on OnBeforePopupAborted, which can arrive after the opener closed.
struct PendingPopup {
  int popupId;
  NSView *parent;
};
std::map<int, std::deque<PendingPopup>> gPopupParents;

class BSClient : public CefClient,
                 public CefLifeSpanHandler,
                 public CefLoadHandler,
                 public CefDisplayHandler,
                 public CefFindHandler,
                 public CefFocusHandler,
                 public CefKeyboardHandler,
                 public CefRequestHandler {
 public:
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
  CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
  CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }

  // Tab ran past the page's last (next) or before its first (previous) focusable element.
  void OnTakeFocus(CefRefPtr<CefBrowser> browser, bool next) override {
    if (gOnTakeFocus) gOnTakeFocus(browser->GetIdentifier(), next);
  }

  bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>, int popupId,
                     const CefString &url,
                     const CefString &, WindowOpenDisposition disposition, bool,
                     const CefPopupFeatures &, CefWindowInfo &window_info, CefRefPtr<CefClient> &,
                     CefBrowserSettings &, CefRefPtr<CefDictionaryValue> &, bool *) override {
    CEF_REQUIRE_UI_THREAD();
    if (!gOnBeforePopup) return true;
    int opener = browser->GetIdentifier();
    NSView *parent = gOnBeforePopup(opener, ToNS(url), disposition == CEF_WOD_NEW_BACKGROUND_TAB);
    if (!parent) return true;
    NSRect b = parent.bounds;
    window_info.SetAsChild((__bridge CefWindowHandle)parent,
                           CefRect(0, 0, (int)b.size.width, (int)b.size.height));
    window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    gPopupParents[opener].push_back({popupId, parent});
    return false;
  }

  bool OnOpenURLFromTab(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>, const CefString &url,
                        WindowOpenDisposition disposition, bool) override {
    bool background = disposition == CEF_WOD_NEW_BACKGROUND_TAB;
    if (!gOnOpenURLInNewTab ||
        (!background && disposition != CEF_WOD_NEW_FOREGROUND_TAB &&
         disposition != CEF_WOD_NEW_WINDOW)) {
      return false;
    }
    gOnOpenURLInNewTab(browser->GetIdentifier(), ToNS(url), background);
    return true;
  }

  void OnBeforePopupAborted(CefRefPtr<CefBrowser> browser, int popupId) override {
    CEF_REQUIRE_UI_THREAD();
    auto it = gPopupParents.find(browser->GetIdentifier());
    if (it == gPopupParents.end()) return;
    auto &pending = it->second;
    for (auto entry = pending.begin(); entry != pending.end(); ++entry) {
      if (entry->popupId != popupId) continue;
      NSView *parent = entry->parent;
      pending.erase(entry);
      if (gOnPopupAborted) gOnPopupAborted(parent);
      return;
    }
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    gBrowsers[browser->GetIdentifier()] = {
        browser, browser->GetHost()->AddDevToolsMessageObserver(new BSObserver())};
    if (!browser->IsPopup()) return;
    // The browser's view sits in the parent we gave it; if it is not attached yet, the oldest
    // request is the best match.
    NSView *view = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
    auto it = gPopupParents.find(browser->GetHost()->GetOpenerIdentifier());
    NSView *parent = nil;
    if (it != gPopupParents.end()) {
      auto &pending = it->second;
      auto entry = pending.begin();
      while (entry != pending.end() && entry->parent != view.superview) ++entry;
      if (entry == pending.end()) entry = pending.begin();
      if (entry != pending.end()) {
        parent = entry->parent;
        pending.erase(entry);
      }
    }
    if (!parent) {
      browser->GetHost()->CloseBrowser(true);
      return;
    }
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    if (gOnPopupCreated) gOnPopupCreated(browser->GetIdentifier(), parent);
  }

  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    // The default (false) makes CEF close the host NSWindow and OnBeforeClose never fires,
    // which hangs shutdown. Detaching the view and returning true lets the browser finish
    // closing, and keeps a close of one tab from closing the window shared by the others.
    NSView *view = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
    [view removeFromSuperview];
    return true;
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    int id = browser->GetIdentifier();
    gBrowsers.erase(id);
    if (gOnBrowserClosed) gOnBrowserClosed(id);
  }

  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool isLoading, bool canGoBack,
                            bool canGoForward) override {
    if (gOnLoadingStateChange) {
      gOnLoadingStateChange(browser->GetIdentifier(), isLoading, canGoBack, canGoForward);
    }
  }

  void OnLoadStart(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                   TransitionType) override {
    if (frame->IsMain() && gOnDocumentCommitted) gOnDocumentCommitted(browser->GetIdentifier());
  }

  void OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, ErrorCode errorCode,
                   const CefString &errorText, const CefString &failedUrl) override {
    if (frame->IsMain() && gOnLoadError) {
      gOnLoadError(browser->GetIdentifier(), (int)errorCode, ToNS(errorText), ToNS(failedUrl));
    }
  }

  void OnFindResult(CefRefPtr<CefBrowser> browser, int, int count, const CefRect &,
                    int activeMatchOrdinal, bool) override {
    if (gOnFindResult) gOnFindResult(browser->GetIdentifier(), count, activeMatchOrdinal);
  }

  bool OnPreKeyEvent(CefRefPtr<CefBrowser>, const CefKeyEvent &event, CefEventHandle os_event,
                     bool *) override {
    if (!gClaimKeyEvent || !os_event) return false;
    bool first = event.type == KEYEVENT_RAWKEYDOWN || event.type == KEYEVENT_KEYDOWN;
    return gClaimKeyEvent((__bridge NSEvent *)os_event, first);
  }

  void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                       const CefString &url) override {
    if (frame->IsMain() && gOnAddressChange) gOnAddressChange(browser->GetIdentifier(), ToNS(url));
  }

  // Page-controlled text and source URLs must not reach Chromium's log file.
  bool OnConsoleMessage(CefRefPtr<CefBrowser>, cef_log_severity_t, const CefString &,
                        const CefString &, int) override {
    return true;
  }

  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString &title) override {
    if (gOnTitleChange) gOnTitleChange(browser->GetIdentifier(), ToNS(title));
  }

 private:
  IMPLEMENT_REFCOUNTING(BSClient);
};

CefRefPtr<BSApp> gApp;
CefRefPtr<BSClient> gClient;

}  // namespace

@implementation BSCef

+ (void (^)(void))onContextInitialized { return gOnContextInitialized; }
+ (void)setOnContextInitialized:(void (^)(void))b { gOnContextInitialized = [b copy]; }
+ (void (^)(int, NSString *))onAddressChange { return gOnAddressChange; }
+ (void)setOnAddressChange:(void (^)(int, NSString *))b { gOnAddressChange = [b copy]; }
+ (void (^)(int, NSString *))onTitleChange { return gOnTitleChange; }
+ (void)setOnTitleChange:(void (^)(int, NSString *))b { gOnTitleChange = [b copy]; }
+ (void (^)(int, BOOL, BOOL, BOOL))onLoadingStateChange { return gOnLoadingStateChange; }
+ (void)setOnLoadingStateChange:(void (^)(int, BOOL, BOOL, BOOL))b {
  gOnLoadingStateChange = [b copy];
}
+ (void (^)(int))onDocumentCommitted { return gOnDocumentCommitted; }
+ (void)setOnDocumentCommitted:(void (^)(int))b { gOnDocumentCommitted = [b copy]; }
+ (void (^)(int, int, int))onFindResult { return gOnFindResult; }
+ (void)setOnFindResult:(void (^)(int, int, int))b { gOnFindResult = [b copy]; }
+ (BOOL (^)(NSEvent *, BOOL))claimKeyEvent { return gClaimKeyEvent; }
+ (void)setClaimKeyEvent:(BOOL (^)(NSEvent *, BOOL))b { gClaimKeyEvent = [b copy]; }
+ (void (^)(int))onBrowserClosed { return gOnBrowserClosed; }
+ (void)setOnBrowserClosed:(void (^)(int))b { gOnBrowserClosed = [b copy]; }

+ (void (^)(int, int, NSString *, NSString *))onLoadError { return gOnLoadError; }
+ (void)setOnLoadError:(void (^)(int, int, NSString *, NSString *))b { gOnLoadError = [b copy]; }

+ (NSView *(^)(int, NSString *, BOOL))onBeforePopup { return gOnBeforePopup; }
+ (void)setOnBeforePopup:(NSView *(^)(int, NSString *, BOOL))b { gOnBeforePopup = [b copy]; }
+ (void (^)(int, NSString *, BOOL))onOpenURLInNewTab { return gOnOpenURLInNewTab; }
+ (void)setOnOpenURLInNewTab:(void (^)(int, NSString *, BOOL))b { gOnOpenURLInNewTab = [b copy]; }
+ (void (^)(int, NSView *))onPopupCreated { return gOnPopupCreated; }
+ (void)setOnPopupCreated:(void (^)(int, NSView *))b { gOnPopupCreated = [b copy]; }
+ (void (^)(NSView *))onPopupAborted { return gOnPopupAborted; }
+ (void)setOnPopupAborted:(void (^)(NSView *))b { gOnPopupAborted = [b copy]; }

+ (void (^)(int, BOOL))onTakeFocus { return gOnTakeFocus; }
+ (void)setOnTakeFocus:(void (^)(int, BOOL))b { gOnTakeFocus = [b copy]; }

+ (void (^)(int, NSData *))onDevToolsMessage { return gOnDevToolsMessage; }
+ (void)setOnDevToolsMessage:(void (^)(int, NSData *))b { gOnDevToolsMessage = [b copy]; }

+ (BOOL)loadFrameworkInMain {
  gLoader = new CefScopedLibraryLoader();
  return gLoader->LoadInMain();
}

+ (BOOL)initializeWithRootCachePath:(NSString *)rootCachePath
                            logFile:(NSString *)logFile
                            verbose:(BOOL)verbose {
  int argc = *_NSGetArgc();
  char **argv = *_NSGetArgv();
  CefMainArgs main_args(argc, argv);

  CefSettings settings;
  settings.persist_session_cookies = true;
  CefString(&settings.root_cache_path) = [rootCachePath UTF8String];
  CefString(&settings.cache_path) = [rootCachePath UTF8String];
  CefString(&settings.log_file) = [logFile UTF8String];
  settings.log_severity = verbose ? LOGSEVERITY_VERBOSE : LOGSEVERITY_WARNING;

  gApp = new BSApp();
  gClient = new BSClient();
  return CefInitialize(main_args, settings, gApp.get(), nullptr);
}

+ (int)createBrowserInView:(NSView *)parent url:(NSString *)url {
  CEF_REQUIRE_UI_THREAD();
  KeepFillingParent();
  NSRect b = parent.bounds;
  CefWindowInfo window_info;
  window_info.SetAsChild((__bridge CefWindowHandle)parent,
                         CefRect(0, 0, (int)b.size.width, (int)b.size.height));
  window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  CefBrowserSettings browser_settings;
  CefRefPtr<CefBrowser> browser = CefBrowserHost::CreateBrowserSync(
      window_info, gClient, CefString([url UTF8String]), browser_settings, nullptr, nullptr);
  if (!browser) return 0;
  NSView *view = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
  view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  return browser->GetIdentifier();
}

+ (void)closeBrowser:(int)browserId {
  auto it = gBrowsers.find(browserId);
  if (it != gBrowsers.end()) it->second.browser->GetHost()->CloseBrowser(true);
}

+ (void)focusBrowser:(int)browserId {
  auto it = gBrowsers.find(browserId);
  if (it != gBrowsers.end()) it->second.browser->GetHost()->SetFocus(true);
}

+ (void)loadURL:(NSString *)url inBrowser:(int)browserId {
  auto it = gBrowsers.find(browserId);
  if (it != gBrowsers.end()) it->second.browser->GetMainFrame()->LoadURL([url UTF8String]);
}

+ (void)goBackInBrowser:(int)browserId {
  auto it = gBrowsers.find(browserId);
  if (it != gBrowsers.end()) it->second.browser->GoBack();
}

+ (void)goForwardInBrowser:(int)browserId {
  auto it = gBrowsers.find(browserId);
  if (it != gBrowsers.end()) it->second.browser->GoForward();
}

+ (void)reloadBrowser:(int)browserId {
  auto it = gBrowsers.find(browserId);
  if (it != gBrowsers.end()) it->second.browser->Reload();
}

+ (void)find:(NSString *)text forward:(BOOL)forward findNext:(BOOL)findNext inBrowser:(int)browserId {
  auto it = gBrowsers.find(browserId);
  if (it != gBrowsers.end()) {
    it->second.browser->GetHost()->Find([text UTF8String], forward, false, findNext);
  }
}

+ (void)stopFindingInBrowser:(int)browserId {
  auto it = gBrowsers.find(browserId);
  if (it != gBrowsers.end()) it->second.browser->GetHost()->StopFinding(true);
}

+ (int)sslStateInBrowser:(int)browserId {
  auto it = gBrowsers.find(browserId);
  if (it == gBrowsers.end()) return 0;
  CefRefPtr<CefNavigationEntry> entry = it->second.browser->GetHost()->GetVisibleNavigationEntry();
  CefRefPtr<CefSSLStatus> ssl = entry ? entry->GetSSLStatus() : nullptr;
  if (!ssl) return 0;
  if (!ssl->IsSecureConnection()) return 3;
  // Bits 16 and up are informational (EV, revocation checking), and a missing revocation answer
  // is not a verdict against the site; Chromium counts neither as an error.
  const uint32_t soft = CERT_STATUS_NO_REVOCATION_MECHANISM | CERT_STATUS_UNABLE_TO_CHECK_REVOCATION;
  return (ssl->GetCertStatus() & 0xFFFFu & ~soft) == 0 ? 1 : 2;
}

+ (void)editCommand:(NSString *)command inBrowser:(int)browserId {
  auto it = gBrowsers.find(browserId);
  if (it == gBrowsers.end()) return;
  CefRefPtr<CefFrame> frame = it->second.browser->GetFocusedFrame();
  if (!frame) return;
  if ([command isEqualToString:@"undo"]) frame->Undo();
  else if ([command isEqualToString:@"redo"]) frame->Redo();
  else if ([command isEqualToString:@"cut"]) frame->Cut();
  else if ([command isEqualToString:@"copy"]) frame->Copy();
  else if ([command isEqualToString:@"paste"]) frame->Paste();
  else if ([command isEqualToString:@"selectAll"]) frame->SelectAll();
}

+ (BOOL)sendDevToolsMessage:(NSString *)json toBrowser:(int)browserId {
  auto it = gBrowsers.find(browserId);
  if (it == gBrowsers.end()) return NO;
  const char *utf8 = [json UTF8String];
  return it->second.browser->GetHost()->SendDevToolsMessage(utf8, strlen(utf8));
}

+ (void)runMessageLoop {
  CefRunMessageLoop();
}

+ (void)quitMessageLoop {
  CefQuitMessageLoop();
}

+ (void)shutdown {
  CefShutdown();
  delete gLoader;
  gLoader = nullptr;
}

@end

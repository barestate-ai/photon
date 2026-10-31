#import "CEFBridge.h"

static BSExceptionSink gOnReportException;

@implementation BSApplication

+ (BSExceptionSink)onReportException { return gOnReportException; }
+ (void)setOnReportException:(BSExceptionSink)sink { gOnReportException = [sink copy]; }

- (void)reportException:(NSException *)exception {
  BSExceptionSink sink = gOnReportException;
  if (sink) sink(exception);
  [super reportException:exception];
}

@end

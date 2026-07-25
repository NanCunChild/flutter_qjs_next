#import "include/FlutterQjsPlugin.h"

@implementation FlutterQjsPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterMethodChannel *channel =
      [FlutterMethodChannel methodChannelWithName:@"flutter_qjs_next"
                                  binaryMessenger:registrar.messenger];
  FlutterQjsPlugin *instance = [[FlutterQjsPlugin alloc] init];
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  if ([@"getPlatformVersion" isEqualToString:call.method]) {
    NSOperatingSystemVersion version =
        [[NSProcessInfo processInfo] operatingSystemVersion];
    result([NSString
        stringWithFormat:@"macOS %ld.%ld.%ld", (long)version.majorVersion,
                         (long)version.minorVersion, (long)version.patchVersion]);
  } else {
    result(FlutterMethodNotImplemented);
  }
}

@end

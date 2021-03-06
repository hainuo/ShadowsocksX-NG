//
//  ProxyConfHelper.m
//  ShadowsocksX-NG
//
//  Created by 邱宇舟 on 16/6/10.
//  Copyright © 2016年 qiuyuzhou. All rights reserved.
//

#import "ProxyConfHelper.h"
#import "proxy_conf_helper_version.h"

#define kShadowsocksHelper @"/Library/Application Support/ShadowsocksX-NG/proxy_conf_helper"

@implementation ProxyConfHelper

GCDWebServer *webServer =nil;
FSEventStreamRef fsEventStream;

+ (BOOL)isVersionOk {
    NSTask *task;
    task = [[NSTask alloc] init];
    [task setLaunchPath:kShadowsocksHelper];
    
    NSArray *args;
    args = [NSArray arrayWithObjects:@"-v", nil];
    [task setArguments: args];
    
    NSPipe *pipe;
    pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    
    NSFileHandle *fd;
    fd = [pipe fileHandleForReading];
    
    [task launch];
    
    NSData *data;
    data = [fd readDataToEndOfFile];
    
    NSString *str;
    str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    
    if (![str isEqualToString:kProxyConfHelperVersion]) {
        return NO;
    }
    return YES;
}

+ (void)install {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:kShadowsocksHelper] || ![self isVersionOk]) {
        NSString *helperPath = [NSString stringWithFormat:@"%@/%@", [[NSBundle mainBundle] resourcePath], @"install_helper.sh"];
        NSLog(@"run install script: %@", helperPath);
        NSDictionary *error;
        NSString *script = [NSString stringWithFormat:@"do shell script \"bash %@\" with administrator privileges", helperPath];
        NSAppleScript *appleScript = [[NSAppleScript new] initWithSource:script];
        if ([appleScript executeAndReturnError:&error]) {
            NSLog(@"installation success");
        } else {
            NSLog(@"installation failure");
        }
    }
}

+ (void)callHelper:(NSArray*) arguments {
    NSTask *task;
    task = [[NSTask alloc] init];
    [task setLaunchPath:kShadowsocksHelper];

    // this log is very important
    NSLog(@"run shadowsocks helper: %@", kShadowsocksHelper);
    [task setArguments:arguments];

    NSPipe *stdoutpipe;
    stdoutpipe = [NSPipe pipe];
    [task setStandardOutput:stdoutpipe];

    NSPipe *stderrpipe;
    stderrpipe = [NSPipe pipe];
    [task setStandardError:stderrpipe];

    NSFileHandle *file;
    file = [stdoutpipe fileHandleForReading];

    [task launch];

    NSData *data;
    data = [file readDataToEndOfFile];

    NSString *string;
    string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (string.length > 0) {
        NSLog(@"%@", string);
    }

    file = [stderrpipe fileHandleForReading];
    data = [file readDataToEndOfFile];
    string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (string.length > 0) {
        NSLog(@"%@", string);
    }
}

+ (void)addArguments4ManualSpecifyNetworkServices:(NSMutableArray*) args {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    
    if (![defaults boolForKey:@"AutoConfigureNetworkServices"]) {
        NSArray* serviceKeys = [defaults arrayForKey:@"Proxy4NetworkServices"];
        if (serviceKeys) {
            for (NSString* key in serviceKeys) {
                [args addObject:@"--network-service"];
                [args addObject:key];
            }
        }
    }
}

+ (NSString*)getPACFilePath {
    return [NSString stringWithFormat:@"%@/%@", NSHomeDirectory(), @".ShadowsocksX-NG/gfwlist.js"];
}

+ (void)enablePACProxy {
    //start server here and then using the string next line
    //next two lines can open gcdwebserver and work around pac file
    NSString* PACFilePath = [self getPACFilePath];
    [self startPACServer: PACFilePath];
    
    NSURL* url = [NSURL URLWithString: [self getHttpPACUrl]];
    
    NSMutableArray* args = [@[@"--mode", @"auto", @"--pac-url", [url absoluteString]]mutableCopy];
    
    [self addArguments4ManualSpecifyNetworkServices:args];
    [self callHelper:args];
}

+ (void)enableGlobalProxy {
    NSUInteger port = [[NSUserDefaults standardUserDefaults]integerForKey:@"LocalSocks5.ListenPort"];
    
    NSMutableArray* args = [@[@"--mode", @"global", @"--port"
                              , [NSString stringWithFormat:@"%lu", (unsigned long)port]]mutableCopy];
    
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"LocalHTTPOn"] && [[NSUserDefaults standardUserDefaults] boolForKey:@"LocalHTTP.FollowGlobel"]) {
        NSUInteger privoxyPort = [[NSUserDefaults standardUserDefaults]integerForKey:@"LocalHTTP.ListenPort"];

        [args addObject:@"--privoxy-port"];
        [args addObject:[NSString stringWithFormat:@"%lu", (unsigned long)privoxyPort]];
    }
    
    [self addArguments4ManualSpecifyNetworkServices:args];
    [self callHelper:args];
    [self stopPACServer];
}

+ (void)disableProxy {
    // 带上所有参数是为了判断是否原有代理设置是否由ssx-ng设置的。如果是用户手工设置的其他配置，则不进行清空。
    NSURL* url = [NSURL URLWithString: [self getHttpPACUrl]];
    NSUInteger port = [[NSUserDefaults standardUserDefaults]integerForKey:@"LocalSocks5.ListenPort"];
    
    NSMutableArray* args = [@[@"--mode", @"off"
                              , @"--port", [NSString stringWithFormat:@"%lu", (unsigned long)port]
                              , @"--pac-url", [url absoluteString]
                              ]mutableCopy];
    [self addArguments4ManualSpecifyNetworkServices:args];
    [self callHelper:args];
    [self stopPACServer];
}

+ (NSString*)getHttpPACUrl {
    NSString * routerPath = @"/proxy.pac";
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    NSString * address = @"127.0.0.1";
    int port = (short)[defaults integerForKey:@"PacServer.ListenPort"];
    
    return [NSString stringWithFormat:@"%@%@:%d%@",@"http://",address,port,routerPath];
}

+ (void)startPACServer:(NSString*) PACFilePath {
    [self stopPACServer];
    
    NSString * routerPath = @"/proxy.pac";
    
    NSData* originalPACData = [NSData dataWithContentsOfFile:PACFilePath];
    
    webServer = [[GCDWebServer alloc] init];
    [webServer addHandlerForMethod:@"GET"
                              path:routerPath
                      requestClass:[GCDWebServerRequest class]
                      processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request)
    {
        GCDWebServerDataResponse* resp = [GCDWebServerDataResponse responseWithData:originalPACData
                                                                        contentType:@"application/x-ns-proxy-autoconfig"];
        return resp;
    }
     ];
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    int port = (short)[defaults integerForKey:@"PacServer.ListenPort"];
    
    [webServer startWithOptions:@{@"BindToLocalhost":@YES, @"Port":@(port)} error:nil];
}

+ (void)stopPACServer {
    //原版似乎没有处理这个，本来设计计划如果切换到全局模式或者手动模式就关掉webserver 似乎没有这个必要了？
    if ([webServer isRunning]) {
        [webServer stop];
    }
}

void onPACChange(
                 ConstFSEventStreamRef streamRef,
                 void *clientCallBackInfo,
                 size_t numEvents,
                 void *eventPaths,
                 const FSEventStreamEventFlags eventFlags[],
                 const FSEventStreamEventId eventIds[])
{
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey:@"ShadowsocksOn"]) {
        if ([[defaults stringForKey:@"ShadowsocksRunningMode"] isEqualToString:@"auto"]) {
            [ProxyConfHelper disableProxy];
            [ProxyConfHelper enablePACProxy];
        }
    }
}

+ (void)startMonitorPAC {
    NSString* PACFilePath = [self getPACFilePath];
    
    if (fsEventStream) {
        return;
    }
    CFStringRef mypath = (__bridge CFStringRef)(PACFilePath);
    CFArrayRef pathsToWatch = CFArrayCreate(NULL, (const void **)&mypath, 1, NULL);
    void *callbackInfo = NULL; // could put stream-specific data here.
    CFAbsoluteTime latency = 3.0; /* Latency in seconds */
    
    /* Create the stream, passing in a callback */
    fsEventStream = FSEventStreamCreate(NULL,
                                        &onPACChange,
                                        callbackInfo,
                                        pathsToWatch,
                                        kFSEventStreamEventIdSinceNow, /* Or a previous event ID */
                                        latency,
                                        kFSEventStreamCreateFlagNone /* Flags explained in reference */
                                        );
    FSEventStreamScheduleWithRunLoop(fsEventStream, [[NSRunLoop mainRunLoop] getCFRunLoop], (__bridge CFStringRef)NSDefaultRunLoopMode);
    FSEventStreamStart(fsEventStream);
}

@end

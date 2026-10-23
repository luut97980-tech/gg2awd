#include "login_probe.hpp"
#include "debug_log.hpp"
#import <Foundation/Foundation.h>

// The login failure "Đã xảy ra lỗi tạm thời khi đăng nhập" is printed by the game
// after its identity endpoint answers, so the reason lives in that response. This
// probe prints it. One install, one log, no A/B matrix.

static NSString* const kProbeKey=@"VTLoginProbe";
static NSString* const kProbeLog=@"login.log";
static const NSUInteger kMaxBodyBytes=320;

@interface VTLoginProtocol : NSURLProtocol
@end

namespace {

NSMutableSet<NSString*>* inFlight(){
    static NSMutableSet* set;
    static dispatch_once_t once;
    dispatch_once(&once,^{set=[NSMutableSet set];});
    return set;
}

NSString* requestKey(NSURLRequest* request){
    return [NSString stringWithFormat:@"%@ %@",request.HTTPMethod,request.URL.absoluteString];
}

}  // namespace

@implementation VTLoginProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest*)request{
    NSString* scheme=request.URL.scheme.lowercaseString;
    if(![scheme isEqualToString:@"http"]&&![scheme isEqualToString:@"https"])return NO;
    // Our own forwarding request carries the marker; intercepting it would loop.
    if([NSURLProtocol propertyForKey:kProbeKey inRequest:request])return NO;
    @synchronized(inFlight()){
        return ![inFlight() containsObject:requestKey(request)];
    }
}

+ (NSURLRequest*)canonicalRequestForRequest:(NSURLRequest*)request{return request;}

- (void)startLoading{
    NSMutableURLRequest* request=[self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:kProbeKey inRequest:request];
    NSString* key=[requestKey(self.request) copy];
    @synchronized(inFlight()){[inFlight() addObject:key];}
    vt::logLineTo(kProbeLog,[NSString stringWithFormat:@"-> %@ %@",request.HTTPMethod,request.URL.absoluteString]);
    // A private ephemeral session: no shared cookie jar, no cache, no recursion.
    NSURLSessionConfiguration* configuration=[NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest=MAX(request.timeoutInterval,5.0);
    NSURLSession* session=[NSURLSession sessionWithConfiguration:configuration];
    NSURLSessionDataTask* task=[session dataTaskWithRequest:request
        completionHandler:^(NSData* data,NSURLResponse* response,NSError* error){
        @synchronized(inFlight()){[inFlight() removeObject:key];}
        [session finishTasksAndInvalidate];
        if(error){
            vt::logLineTo(kProbeLog,[NSString stringWithFormat:@"<- ERR %@ %@",request.URL.path,error.localizedDescription]);
            [self.client URLProtocol:self didFailWithError:error];
            return;
        }
        if([response isKindOfClass:NSHTTPURLResponse.class]){
            NSHTTPURLResponse* http=(NSHTTPURLResponse*)response;
            NSString* body=nil;
            if(data.length){
                body=[[NSString alloc]initWithData:[data subdataWithRange:NSMakeRange(0,MIN(data.length,kMaxBodyBytes))]
                                          encoding:NSUTF8StringEncoding];
            }
            vt::logLineTo(kProbeLog,[NSString stringWithFormat:@"<- %ld %@ %@",
                (long)http.statusCode,http.URL.path,body?:@"<binary>"]);
        }
        [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        if(data.length)[self.client URLProtocol:self didLoadData:data];
        [self.client URLProtocolDidFinishLoading:self];
    }];
    [task resume];
}

- (void)stopLoading{}

@end

void vt::installLoginProbe(){
    static dispatch_once_t once;
    dispatch_once(&once,^{
        NSURL* off=[vt::stateFolder() URLByAppendingPathComponent:@"noprobe"];
        if([[NSFileManager defaultManager]fileExistsAtPath:off.path])return;
        [NSURLProtocol registerClass:VTLoginProtocol.class];
        vt::logLineTo(kProbeLog,@"probe installed");
    });
}

#include "debug_log.hpp"
#import <QuartzCore/QuartzCore.h>

namespace {

constexpr unsigned long long kMaxLogBytes=256*1024;

}  // namespace

NSURL* vt::stateFolder(){
    static NSURL* folder;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        NSURL* base=[[NSFileManager defaultManager]URLsForDirectory:NSApplicationSupportDirectory
                                                           inDomains:NSUserDomainMask].firstObject;
        folder=[base URLByAppendingPathComponent:@"VTMenu" isDirectory:YES];
        [[NSFileManager defaultManager]createDirectoryAtURL:folder
                                 withIntermediateDirectories:YES attributes:nil error:nil];
    });
    return folder;
}

void vt::logLineTo(NSString* file,NSString* line){
    if(!line)return;
    @autoreleasepool{
        NSURL* url=[vt::stateFolder() URLByAppendingPathComponent:file];
        NSDictionary* attributes=[[NSFileManager defaultManager]attributesOfItemAtPath:url.path error:nil];
        if([attributes[NSFileSize] unsignedLongLongValue]>=kMaxLogBytes)return;
        NSString* stamp=[NSString stringWithFormat:@"%.3f %@\n",CACurrentMediaTime(),line];
        NSData* data=[stamp dataUsingEncoding:NSUTF8StringEncoding];
        if(!data)return;
        NSFileHandle* handle=[NSFileHandle fileHandleForWritingAtPath:url.path];
        if(handle){
            @try{
                [handle seekToEndOfFile];
                [handle writeData:data];
            }@finally{
                [handle closeFile];
            }
            return;
        }
        [data writeToURL:url atomically:YES];
    }
}

void vt::logLine(NSString* line){vt::logLineTo(@"menu.log",line);}

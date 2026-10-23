#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#include "mobile_menu.hpp"
#include "game_backend.hpp"
#include "ios_build_guard.hpp"
#include "app_metadata_apple.hpp"
#include "generated_font.hpp"
#include "debug_log.hpp"
#include "login_probe.hpp"
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <cstring>
#include <cstdio>
#include <memory>
#include "imgui_impl_metal.h"
#include <cfloat>
#include <cmath>
#include <algorithm>
#include <cstdarg>
#include <limits>

static void* VTUnityHandle=nullptr;
static std::string VTGuardMessage,VTGuardDetails;
static bool VTGuardMayRetry=true;
static bool VTCheckBuild(){
    VTGuardMayRetry=true;
    const auto metadata=vt::ios::readAppMetadata();
    const auto decision=vt::ios::chooseMetadata(metadata.disk,metadata.bundle);
    VTGuardDetails=vt::ios::metadataReport(metadata)+"\nMetadata source: "+decision.source;
    if(!decision.compatible){
        VTGuardMayRetry=decision.retryable;
        const auto& observed=metadata.disk.present?metadata.disk:metadata.bundle;
        VTGuardMessage=decision.retryable?"Waiting for app metadata":
            "App metadata mismatch: "+vt::ios::metadataLine("observed",observed);
        return false;
    }
    for(uint32_t i=0;i<_dyld_image_count();++i){
        const char*name=_dyld_get_image_name(i);if(!name||!strstr(name,"/UnityFramework.framework/UnityFramework"))continue;
        const auto*h=reinterpret_cast<const mach_header_64*>(_dyld_get_image_header(i));
        if(!h||h->magic!=MH_MAGIC_64||h->cputype!=CPU_TYPE_ARM64||h->ncmds>4096||h->sizeofcmds>1048576){VTGuardMayRetry=false;VTGuardMessage="Invalid UnityFramework Mach-O header";return false;}
        const auto*base=reinterpret_cast<const unsigned char*>(h);const unsigned char*cmd=base+sizeof(*h),*end=cmd+h->sizeofcmds;
        std::string uuid;uint64_t textStart=0,textEnd=0;
        for(uint32_t j=0;j<h->ncmds;++j){
            if(cmd+sizeof(load_command)>end){VTGuardMayRetry=false;VTGuardMessage="Invalid Mach-O command table";return false;}
            const auto*lc=reinterpret_cast<const load_command*>(cmd);if(lc->cmdsize<sizeof(*lc)||cmd+lc->cmdsize>end){VTGuardMayRetry=false;VTGuardMessage="Invalid Mach-O command";return false;}
            if(lc->cmd==LC_UUID&&lc->cmdsize>=sizeof(uuid_command)){auto*u=reinterpret_cast<const uuid_command*>(cmd);char hex[33];for(int k=0;k<16;k++)snprintf(hex+k*2,3,"%02x",u->uuid[k]);uuid=hex;}
            if(lc->cmd==LC_SEGMENT_64&&lc->cmdsize>=sizeof(segment_command_64)){auto*seg=reinterpret_cast<const segment_command_64*>(cmd);if(strncmp(seg->segname,"__TEXT",16)==0){textStart=seg->vmaddr;textEnd=textStart+seg->vmsize;}}
            cmd+=lc->cmdsize;
        }
        VTGuardDetails+="\nUnityFramework UUID: "+uuid+"\nExpected UUID: "+vt::ios::ExpectedFrameworkUUID;
        if(uuid!=vt::ios::ExpectedFrameworkUUID){VTGuardMayRetry=false;VTGuardMessage="UnityFramework UUID mismatch";return false;}
        for(const auto&g:vt::ios::MethodGuards){
            if(g.rva<textStart||g.rva>textEnd||g.bytes.size()>textEnd-g.rva||memcmp(base+g.rva,g.bytes.data(),g.bytes.size())!=0){
                char detail[80];snprintf(detail,sizeof(detail),"iOS method signature mismatch at RVA 0x%llx",static_cast<unsigned long long>(g.rva));
                VTGuardMayRetry=false;VTGuardMessage=detail;return false;
            }
        }
        if(!VTUnityHandle)VTUnityHandle=dlopen(name,RTLD_LAZY|RTLD_NOLOAD);
        if(!VTUnityHandle){VTGuardMessage="UnityFramework is not loaded";return false;}
        VTGuardMessage="Installed app metadata + UUID + iOS method signatures confirmed";return true;
    }
    VTGuardMessage="Waiting for UnityFramework (will retry)";return false;
}

static CFTimeInterval VTLaunchTime=0;
static bool VTAttachForced=false;

// The menu must not be part of the login scene. VNG's sign-in path refuses a
// client it does not like, and an extra UIWindow above UIWindowLevelAlert is the
// most visible thing an injected dylib can leave lying around. Attach is held
// back until the app has been alive for a while, so launch + login finish first.
static const CFTimeInterval VTDefaultAttachDelay=8.0;

static NSURL* VTStateFolder(){
    return vt::stateFolder();
}

// Presence of VTMenu/safe keeps the dylib loaded but completely inert: no window,
// no observers, no IL2CPP call. That is the control install for any login fault.
static bool VTSafeBootRequested(){
    return [[NSFileManager defaultManager]fileExistsAtPath:[VTStateFolder() URLByAppendingPathComponent:@"safe"].path];
}

static CFTimeInterval VTAttachDelay(){
    NSData*data=[NSData dataWithContentsOfURL:[VTStateFolder() URLByAppendingPathComponent:@"config.json"]];
    id parsed=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    if([parsed isKindOfClass:NSDictionary.class]){
        id value=((NSDictionary*)parsed)[@"attach_delay_s"];
        if([value isKindOfClass:NSNumber.class]){
            const double seconds=[value doubleValue];
            if(std::isfinite(seconds))return std::clamp(seconds,0.0,120.0);
        }
    }
    return VTDefaultAttachDelay;
}

// "subview" (default) hosts the menu inside the game's own UIWindow, so the
// login path never sees a second window. "window" keeps the R5.3 overlay window
// for devices where the game tears its window's subviews down.
static bool VTAttachModeSubview(){
    NSData*data=[NSData dataWithContentsOfURL:[VTStateFolder() URLByAppendingPathComponent:@"config.json"]];
    id parsed=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    if([parsed isKindOfClass:NSDictionary.class]){
        id value=((NSDictionary*)parsed)[@"attach_mode"];
        if([value isKindOfClass:NSString.class]&&[value isEqualToString:@"window"])return false;
    }
    return true;
}

static void VTLog(NSString*format,...){
    va_list args;va_start(args,format);
    NSString*line=[[NSString alloc]initWithFormat:format arguments:args];
    va_end(args);
    vt::logLine(line);
}

@interface VTMetalView : MTKView
@property(nonatomic,weak) id touchOwner;
@end
@interface VTMenuController : UIViewController<MTKViewDelegate> {
    ImGuiContext* _context;
    vt::ios::Model _model;
    vt::ios::Actions _actions;
    std::unique_ptr<vt::ios::GameBackend> _backend;
    UITouch* _primaryTouch;
    CGPoint _touchStart,_touchPrevious;
    BOOL _panning;
    CFTimeInterval _lastFrame,_nextBuildCheck,_resumeAfter;
    CGSize _lastLayoutSize;
    int _loadedLogTab;
    CFTimeInterval _logRefreshAt;
}
@property(nonatomic,strong) VTMetalView* metalView;
@property(nonatomic,strong) id<MTLDevice> device;
@property(nonatomic,strong) id<MTLCommandQueue> commandQueue;
-(void)beginTouches:(NSSet<UITouch*>*)touches;
-(void)moveTouches:(NSSet<UITouch*>*)touches;
-(void)endTouches:(NSSet<UITouch*>*)touches cancelled:(BOOL)cancelled;
-(void)setRenderingActive:(BOOL)active;
-(BOOL)acceptsPoint:(CGPoint)point;
-(void)tryStartBackend:(CFTimeInterval)now;
-(void)refreshLog:(BOOL)force;
-(void)copyLog;
@end
@interface VTPassthroughView:UIView
@property(nonatomic,weak) VTMenuController*menuController;
@end
@implementation VTPassthroughView
-(UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event{
    if(self.hidden||self.alpha<.01||!self.userInteractionEnabled||![self pointInside:point withEvent:event]||!self.menuController.metalView)return nil;
    CGPoint local=[self.menuController.metalView convertPoint:point fromView:self];
    if(![self.menuController acceptsPoint:local])return nil;
    return [super hitTest:point withEvent:event];
}
@end

@implementation VTMetalView
-(void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event{[(VTMenuController*)self.touchOwner beginTouches:touches];}
-(void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event{[(VTMenuController*)self.touchOwner moveTouches:touches];}
-(void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event{[(VTMenuController*)self.touchOwner endTouches:touches cancelled:NO];}
-(void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event{[(VTMenuController*)self.touchOwner endTouches:touches cancelled:YES];}
@end

@implementation VTMenuController
-(void)loadView{
    VTPassthroughView*root=[[VTPassthroughView alloc]initWithFrame:CGRectZero];root.menuController=self;
    self.view=root;self.view.backgroundColor=UIColor.clearColor;self.view.opaque=NO;
}
-(NSURL*)settingsURL{
    NSURL*base=[[NSFileManager defaultManager]URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL*folder=[base URLByAppendingPathComponent:@"VTMenu" isDirectory:YES];
    [[NSFileManager defaultManager]createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    return [folder URLByAppendingPathComponent:@"config.json"];
}
-(void)restoreSettings{
    NSData*data=[NSData dataWithContentsOfURL:[self settingsURL]];
    id parsed=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    NSDictionary*saved=[parsed isKindOfClass:NSDictionary.class]?parsed:@{};
    if([saved[@"scale"] isKindOfClass:NSNumber.class])_model.scale=[saved[@"scale"] floatValue];
    if([saved[@"opacity"] isKindOfClass:NSNumber.class])_model.opacity=[saved[@"opacity"] floatValue];
    if([saved[@"jump_interval_ms"] isKindOfClass:NSNumber.class])_model.jumpIntervalMs=[saved[@"jump_interval_ms"]doubleValue];
    else {NSArray*old=saved[@"numbers"];if([old isKindOfClass:NSArray.class]&&old.count==4&&[old[3] isKindOfClass:NSNumber.class])_model.jumpIntervalMs=[old[3]doubleValue];}
    vt::ios::sanitize(_model);_model.enabled.fill(false);_model.visible=false;
}
-(void)saveSettings{
    vt::ios::sanitize(_model);
    // Keep keys this build does not own (attach_delay_s and anything a future
    // build adds); writing a fresh dictionary silently deleted them.
    NSData*old=[NSData dataWithContentsOfURL:[self settingsURL]];
    id parsed=old?[NSJSONSerialization JSONObjectWithData:old options:0 error:nil]:nil;
    NSMutableDictionary*settings=[parsed isKindOfClass:NSDictionary.class]?[parsed mutableCopy]:[NSMutableDictionary dictionary];
    settings[@"schema"]=@3;settings[@"scale"]=@(_model.scale);settings[@"opacity"]=@(_model.opacity);settings[@"jump_interval_ms"]=@(_model.jumpIntervalMs);
    NSData*data=[NSJSONSerialization dataWithJSONObject:settings options:NSJSONWritingPrettyPrinted error:nil];
    NSError*error=nil;
    if(!data||![data writeToURL:[self settingsURL] options:NSDataWritingAtomic error:&error])_model.status="Không ghi được config.json";
}
-(BOOL)acceptsPoint:(CGPoint)p{
    return vt::ios::acceptsPoint(_model,{float(p.x),float(p.y)});
}
// Reads the selected log straight from the app container; the menu shows it and
// copies it to the clipboard, so no PC, Filza or Xcode is needed to read it.
-(void)refreshLog:(BOOL)force{
    if(!_model.showLog)return;
    const CFTimeInterval now=CACurrentMediaTime();
    if(!force&&_loadedLogTab==_model.logTab&&now<_logRefreshAt)return;
    _loadedLogTab=_model.logTab;_logRefreshAt=now+.5;
    NSString*name=_model.logTab==1?@"login.log":@"menu.log";
    NSURL*url=[VTStateFolder() URLByAppendingPathComponent:name];
    NSString*text=[NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
    // A 256 KB log cannot be drawn every frame; the tail is what diagnoses the
    // failure anyway, and the copy button copies exactly what is on screen.
    const NSUInteger tailBytes=16000;
    if(text.length>tailBytes)text=[@"…\n" stringByAppendingString:[text substringFromIndex:text.length-tailBytes]];
    const char*utf8=text.UTF8String;
    _model.logText=utf8?utf8:"";
    const char*path=url.path.UTF8String;
    _model.logPath=path?path:"";
}
-(void)copyLog{
    [self refreshLog:YES];
    UIPasteboard.generalPasteboard.string=[NSString stringWithUTF8String:_model.logText.c_str()];
    _model.toast=_model.logText.empty()?std::string("Log trống"):std::string("Đã sao chép log");
    _model.toastUntil=_model.time+2.;
}
-(void)viewDidLoad{
    [super viewDidLoad];[self restoreSettings];self.device=MTLCreateSystemDefaultDevice();
    if(!self.device){UILabel*label=[[UILabel alloc]initWithFrame:self.view.bounds];label.text=@"Thiết bị không khởi tạo được Metal.";label.textColor=UIColor.whiteColor;label.numberOfLines=0;label.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;[self.view addSubview:label];return;}
    self.commandQueue=[self.device newCommandQueue];
    self.metalView=[[VTMetalView alloc]initWithFrame:CGRectZero device:self.device];self.metalView.delegate=self;self.metalView.touchOwner=self;
    self.metalView.multipleTouchEnabled=YES;self.metalView.preferredFramesPerSecond=60;
    self.metalView.colorPixelFormat=MTLPixelFormatBGRA8Unorm;self.metalView.opaque=NO;self.metalView.layer.opaque=NO;self.metalView.backgroundColor=UIColor.clearColor;self.metalView.clearColor=MTLClearColorMake(0,0,0,0);
    self.metalView.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:self.metalView];
    UIView*g=self.view;
    [NSLayoutConstraint activateConstraints:@[[self.metalView.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],[self.metalView.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],[self.metalView.topAnchor constraintEqualToAnchor:g.topAnchor],[self.metalView.bottomAnchor constraintEqualToAnchor:g.bottomAnchor]]];
    IMGUI_CHECKVERSION();_context=ImGui::CreateContext();ImGuiIO&io=ImGui::GetIO();io.IniFilename=nullptr;io.LogFilename=nullptr;io.ConfigFlags|=ImGuiConfigFlags_NoMouseCursorChange;
    CGFloat scale=UIScreen.mainScreen.scale;ImFontConfig cfg;cfg.OversampleH=2;cfg.OversampleV=1;cfg.FontDataOwnedByAtlas=false;
    io.Fonts->AddFontFromMemoryTTF(const_cast<unsigned char*>(vt::ios::FontBytes),int(sizeof(vt::ios::FontBytes)),16.f*scale,&cfg,io.Fonts->GetGlyphRangesVietnamese());
    if(io.Fonts->Fonts.empty())io.Fonts->AddFontDefault();
    // Rasterize at Retina scale, then return glyph geometry to UIKit points.
    for(ImFont*f:io.Fonts->Fonts)f->Scale=1.f/float(scale);
    vt::ios::style();ImGui_ImplMetal_Init(self.device);
    _model.available.fill(false);
    for(int id:{vt::Esp,vt::SpamJump})_model.available[id]=true;
    _resumeAfter=0;
    [self tryStartBackend:CACurrentMediaTime()];
    __weak VTMenuController*weakSelf=self;
    _actions.save=[weakSelf]{VTMenuController*strong=weakSelf;if(strong)[strong saveSettings];};
    _actions.stop=[weakSelf]{VTMenuController*strong=weakSelf;if(strong&&strong->_backend)strong->_backend->stop(strong->_model);};
    _actions.number=[weakSelf](int,double){VTMenuController*strong=weakSelf;if(strong)[strong saveSettings];};
    _actions.toggle=[weakSelf](int id){VTMenuController*strong=weakSelf;if(strong&&strong->_backend)strong->_backend->toggle(strong->_model,id);};
    _actions.diagnostic=[weakSelf]{VTMenuController*strong=weakSelf;if(strong){
        if(!strong->_backend){strong->_nextBuildCheck=0;[strong tryStartBackend:CACurrentMediaTime()];}
        const auto metadata=vt::ios::readAppMetadata();
        UIView*host=strong.view.superview;const CGSize size=host.bounds.size;const CGAffineTransform t=host.transform;const UIEdgeInsets insets=host.safeAreaInsets;
        const char*hostClass=NSStringFromClass(host.class).UTF8String;char hostInfo[320];
        snprintf(hostInfo,sizeof(hostInfo),"UI container: %s; bounds=%.0fx%.0f; inset=%.0f,%.0f,%.0f,%.0f; orientation=%ld; transform=%.2f,%.2f,%.2f,%.2f",hostClass?hostClass:"none",double(size.width),double(size.height),double(insets.top),double(insets.left),double(insets.bottom),double(insets.right),long(host.window.windowScene.interfaceOrientation),double(t.a),double(t.b),double(t.c),double(t.d));
        char attachInfo[160];
        snprintf(attachInfo,sizeof(attachInfo),"Attach: %.1fs after launch; delay=%.1fs; safe boot=%s",double(CACurrentMediaTime()-VTLaunchTime),double(VTAttachDelay()),VTSafeBootRequested()?"yes":"no");
        strong->_model.diagnostic="PTG iOS R5.6 | target VNG 2.32.0 (227628) | arm64\n"+VTGuardMessage+"\n"+VTGuardDetails+
            "\n"+std::string(hostInfo)+"\n"+std::string(attachInfo)+"\nCurrent metadata:\n"+vt::ios::metadataReport(metadata)+"\nStatus: "+strong->_model.status+"\n"+
            (strong->_backend?strong->_backend->diagnostic():"Backend unavailable")+
            "\nWeb key client and capture hiding are not implemented on iOS.";
        UIPasteboard.generalPasteboard.string=[NSString stringWithUTF8String:strong->_model.diagnostic.c_str()];
        strong->_model.toast="Đã sao chép chẩn đoán";strong->_model.toastUntil=strong->_model.time+1.;
    }};
    _actions.logRefresh=[weakSelf]{VTMenuController*strong=weakSelf;if(strong)[strong refreshLog:YES];};
    _actions.logCopy=[weakSelf]{VTMenuController*strong=weakSelf;if(strong)[strong copyLog];};

}
-(void)tryStartBackend:(CFTimeInterval)now{
    if(_backend||now<_nextBuildCheck)return;
    _model.connected=false;_model.controlsAllowed=false;
    if(!VTCheckBuild()){
        _model.status=VTGuardMessage;
        _nextBuildCheck=VTGuardMayRetry?now+1.:std::numeric_limits<double>::infinity();
        return;
    }
    try{
        _backend=std::make_unique<vt::ios::GameBackend>([](const char*n){return dlsym(VTUnityHandle,n);});
        _model.connected=true;_model.controlsAllowed=true;
        _model.status="Đã xác minh bản game; bật ESP hoặc Spam nhảy";
    }catch(const std::exception&e){
        _model.status=e.what();_nextBuildCheck=std::numeric_limits<double>::infinity();
    }
}
-(void)viewDidLayoutSubviews{
    [super viewDidLayoutSubviews];
    const CGSize size=self.view.bounds.size;
    if(!CGSizeEqualToSize(size,_lastLayoutSize)){
        [self cancelMouse];_primaryTouch=nil;_panning=NO;_model.scrollDelta=0;_model.suppressActions=true;
        _model.windowMin=_model.windowMax={};_lastLayoutSize=size;
        // Layout churn (rotation, keyboard, scene swap) means the game is moving
        // views around; hold every managed call until the frame settles.
        if(_backend)_backend->suspend(CACurrentMediaTime());
    }
}
-(void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator{
    [self cancelMouse];_primaryTouch=nil;_panning=NO;_model.scrollDelta=0;_model.suppressActions=true;
    _model.windowMin=_model.windowMax={};
    if(_backend)_backend->suspend(CACurrentMediaTime());
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
}
-(BOOL)prefersStatusBarHidden{return YES;}
-(BOOL)shouldAutorotate{return YES;}
-(UIInterfaceOrientationMask)supportedInterfaceOrientations{return UIInterfaceOrientationMaskAll;}
-(void)cancelMouse{
    if(!_context)return;ImGui::SetCurrentContext(_context);auto&io=ImGui::GetIO();io.AddMouseSourceEvent(ImGuiMouseSource_TouchScreen);io.AddMousePosEvent(-FLT_MAX,-FLT_MAX);io.AddMouseButtonEvent(0,false);
}
-(void)beginTouches:(NSSet<UITouch*>*)touches{
    if(!_context||_primaryTouch)return;_primaryTouch=touches.anyObject;
    _touchStart=_touchPrevious=[_primaryTouch locationInView:self.metalView];_panning=NO;_model.suppressActions=false;
    ImGui::SetCurrentContext(_context);auto&io=ImGui::GetIO();io.AddMouseSourceEvent(ImGuiMouseSource_TouchScreen);io.AddMousePosEvent(_touchStart.x,_touchStart.y);io.AddMouseButtonEvent(0,true);
}
-(void)moveTouches:(NSSet<UITouch*>*)touches{
    if(!_context||!_primaryTouch||![touches containsObject:_primaryTouch])return;
    CGPoint p=[_primaryTouch locationInView:self.metalView];CGFloat dx=p.x-_touchStart.x,dy=p.y-_touchStart.y;
    const BOOL inContent=_touchStart.x>=_model.contentMin.x&&_touchStart.x<_model.contentMax.x&&_touchStart.y>=_model.contentMin.y&&_touchStart.y<_model.contentMax.y;
    if(!_panning&&_model.visible&&inContent&&!_model.sliderActive&&fabs(dy)>14&&fabs(dy)>fabs(dx)*1.5){_panning=YES;_model.suppressActions=true;[self cancelMouse];}
    if(_panning){_model.scrollDelta+=p.y-_touchPrevious.y;}
    else{ImGui::SetCurrentContext(_context);ImGui::GetIO().AddMousePosEvent(p.x,p.y);}
    _touchPrevious=p;
}
-(void)endTouches:(NSSet<UITouch*>*)touches cancelled:(BOOL)cancelled{
    if(!_context||!_primaryTouch||![touches containsObject:_primaryTouch])return;
    ImGui::SetCurrentContext(_context);
    if(cancelled||_panning){_model.suppressActions=true;[self cancelMouse];}
    else{CGPoint p=[_primaryTouch locationInView:self.metalView];auto&io=ImGui::GetIO();io.AddMousePosEvent(p.x,p.y);io.AddMouseButtonEvent(0,false);}
    _primaryTouch=nil;_panning=NO;
}
-(void)setRenderingActive:(BOOL)active{
    [self cancelMouse];_primaryTouch=nil;_panning=NO;_model.scrollDelta=0;_model.suppressActions=true;
    if(!active){if(_backend)_backend->stop(_model);_model.visible=false;_model.enabled.fill(false);[self saveSettings];_resumeAfter=0;}
    else{
        // On return from background the game rebuilds its scene first; do not
        // call into the runtime during that window.
        _resumeAfter=CACurrentMediaTime()+1.;
        if(_backend)_backend->suspend(CACurrentMediaTime());
    }
    self.metalView.paused=!active;_lastFrame=0;
}
-(void)drawInMTKView:(MTKView*)view{
    if(!_context||view.paused||view.bounds.size.width<=0||view.bounds.size.height<=0)return;
    ImGui::SetCurrentContext(_context);auto&io=ImGui::GetIO();io.DisplaySize={float(view.bounds.size.width),float(view.bounds.size.height)};
    io.DisplayFramebufferScale={float(view.drawableSize.width/view.bounds.size.width),float(view.drawableSize.height/view.bounds.size.height)};
    CFTimeInterval now=CACurrentMediaTime();io.DeltaTime=_lastFrame?float(fmin(.1,fmax(.001,now-_lastFrame))):1.f/60;_lastFrame=now;
    // Rotation, stage-manager resize and split-view drags arrive here before the
    // controller's layout pass; drop any in-flight touch so a release is not
    // delivered against the previous orientation's rectangles.
    const CGSize bounds=view.bounds.size;
    if(!CGSizeEqualToSize(bounds,_lastLayoutSize)){
        [self cancelMouse];_primaryTouch=nil;_panning=NO;_model.scrollDelta=0;_model.suppressActions=true;
        _model.windowMin=_model.windowMax={};_lastLayoutSize=bounds;
        if(_backend)_backend->suspend(now);
    }
    id<CAMetalDrawable> drawable=view.currentDrawable;MTLRenderPassDescriptor*pass=view.currentRenderPassDescriptor;if(!drawable||!pass)return;
    id<MTLCommandBuffer>command=[self.commandQueue commandBuffer];if(!command)return;
    _model.time=now;_model.insetMin={float(view.safeAreaInsets.left),float(view.safeAreaInsets.top)};_model.insetMax={float(view.safeAreaInsets.right),float(view.safeAreaInsets.bottom)};
    [self tryStartBackend:now];
    // The render loop is a UIKit/show-link frame, not Unity's player thread.
    // Keep game calls out of it while the app is resuming, and the backend
    // itself keeps them off until a feature is actually switched on.
    if(now>=_resumeAfter&&_backend)_backend->tick(_model,now);
    bool busy=_model.visible||vt::ios::runtimeRequested(_model);view.preferredFramesPerSecond=busy?60:15;
    ImGui_ImplMetal_NewFrame(pass);ImGui::NewFrame();
    if(_backend&&_model.enabled[vt::Esp]){
        auto*d=ImGui::GetBackgroundDrawList();const float w=io.DisplaySize.x,h=io.DisplaySize.y;
        for(const auto&p:_backend->esp()){float x=p.x*w,bottom=p.y*h,top=p.headY*h,height=fabsf(bottom-top);if(height<4||height>h*2)continue;
            float left=x-height*.2f,right=x+height*.2f;ImU32 col=IM_COL32(183,174,255,220);
            d->AddRect({left,top},{right,bottom},col,2,0,1.5f);char label[100];snprintf(label,sizeof(label),"%s | %.0f m",p.label.c_str(),p.distance);d->AddText({left,top-18},col,label);
        }
    }
    [self refreshLog:NO];
    vt::ios::draw(_model,_actions);ImGui::Render();
    id<MTLRenderCommandEncoder>encoder=[command renderCommandEncoderWithDescriptor:pass];if(!encoder)return;
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(),command,encoder);[encoder endEncoding];[command presentDrawable:drawable];[command commit];
}
-(void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size{}
-(void)dealloc{
    if(_backend){_backend->stop(_model);_backend.reset();}
    _metalView.delegate=nil;_metalView.touchOwner=nil;
    if(_context){ImGui::SetCurrentContext(_context);ImGui_ImplMetal_Shutdown();ImGui::DestroyContext(_context);_context=nullptr;}
}
@end

// The menu lives in its own dedicated passthrough window attached to the
// active UIWindowScene of the game. This cleanly avoids inheriting Unity
// view transforms, avoids modifying the game viewController hierarchy, and
// completely eliminates UIViewControllerHierarchyInconsistency crashes on iOS 18.
@interface VTPassthroughWindow : UIWindow
@end

@implementation VTPassthroughWindow
-(UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event{
    UIView*hit=[super hitTest:point withEvent:event];
    if(hit==self||hit==self.rootViewController.view)return nil;
    return hit;
}
@end

static VTPassthroughWindow* VTWindow;
static VTMenuController* VTController;
static __weak UIWindowScene* VTHostScene;
static __weak UIWindow* VTHostWindow;
static __weak UIView* VTSubviewHost;
static NSTimer* VTHostTimer;

static UIView* VTFindGameView(UIView*view,int depth){
    if(!view||depth>24||view.hidden||view.alpha<.01||!view.window||[view isKindOfClass:VTPassthroughView.class])return nil;
    Class unity=NSClassFromString(@"UnityView"),rendering=NSClassFromString(@"UnityRenderingView");
    const bool unityView=unity&&[view isKindOfClass:unity];
    if((rendering&&[view isKindOfClass:rendering])||(unityView&&[view.layer isKindOfClass:CAMetalLayer.class]))return view;
    for(UIView*child in view.subviews){UIView*found=VTFindGameView(child,depth+1);if(found)return found;}
    if([view.layer isKindOfClass:CAMetalLayer.class]||unityView)return view;
    return nil;
}

static void VTDetach(){
    if(!VTController&&!VTWindow)return;
    if(VTController)[VTController setRenderingActive:NO];
    if(VTController&&VTController.view.superview&&VTController.view.superview==VTSubviewHost)[VTController.view removeFromSuperview];
    if(VTWindow){
        VTWindow.hidden=YES;
        VTWindow.rootViewController=nil;
        VTWindow=nil;
    }
    VTController=nil;VTHostScene=nil;VTHostWindow=nil;VTSubviewHost=nil;
}

static void VTAttach(){
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{VTAttach();});return;}
    if(UIApplication.sharedApplication.applicationState!=UIApplicationStateActive)return;
    if(VTSafeBootRequested()){
        if(VTWindow||VTController)VTDetach();
        return;
    }
    const CFTimeInterval now=CACurrentMediaTime();
    if(!VTAttachForced&&now<VTLaunchTime+VTAttachDelay())return;
    UIWindow*game=nil;UIView*unity=nil;
    for(UIScene*scene in UIApplication.sharedApplication.connectedScenes){
        if(![scene isKindOfClass:UIWindowScene.class]||scene.activationState!=UISceneActivationStateForegroundActive)continue;
        for(UIWindow*window in ((UIWindowScene*)scene).windows){
            if(window==VTWindow)continue;
            if(window.hidden||window.alpha<.01||window.windowLevel!=UIWindowLevelNormal||![window.rootViewController isViewLoaded])continue;
            UIView*found=VTFindGameView(window.rootViewController.view,0);
            if(!found)continue;
            if(!game||[window isKeyWindow]){game=window;unity=found;}
            if([window isKeyWindow])break;
        }
        if(game&&[game isKeyWindow])break;
    }
    if(!game||!unity)return;
    UIWindowScene*scene=game.windowScene;
    if(!scene)return;
    const CGSize size=game.bounds.size;
    if(size.width<=0||size.height<=0)return;

    const bool reuseWindow=VTWindow&&VTController&&VTHostWindow==game&&VTWindow.windowScene==scene&&!VTWindow.hidden;
    const bool reuseSubview=!VTWindow&&VTController&&VTHostWindow==game&&VTController.view.superview==game;
    if(reuseWindow||reuseSubview){
        UIView*mounted=reuseWindow?(UIView*)VTWindow:VTController.view;
        if(!CGRectEqualToRect(mounted.frame,game.bounds))mounted.frame=game.bounds;
        if(VTController.view.hidden||VTController.metalView.paused){
            VTController.view.hidden=NO;
            [VTController setRenderingActive:YES];
        }
        return;
    }

    VTDetach();
    VTController=[VTMenuController new];
    VTHostScene=scene;
    VTHostWindow=game;
    if(VTAttachModeSubview()){
        VTController.view.frame=game.bounds;
        VTController.view.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
        [game addSubview:VTController.view];
        VTController.view.hidden=NO;
        VTSubviewHost=game;
        VTLog(@"attached subview to %@ %.0fx%.0f after %.1fs",NSStringFromClass(game.class),double(size.width),double(size.height),double(CACurrentMediaTime()-VTLaunchTime));
        return;
    }
    VTWindow=[[VTPassthroughWindow alloc] initWithWindowScene:scene];
    VTWindow.frame=game.bounds;
    VTWindow.backgroundColor=UIColor.clearColor;
    VTWindow.opaque=NO;
    VTWindow.windowLevel=UIWindowLevelAlert+100;
    VTWindow.rootViewController=VTController;
    VTWindow.hidden=NO;
    VTLog(@"attached overlay window to %@ %.0fx%.0f after %.1fs",NSStringFromClass(game.class),double(size.width),double(size.height),double(CACurrentMediaTime()-VTLaunchTime));
}

extern "C" __attribute__((visibility("default"))) void VTMenuStart(){
    dispatch_async(dispatch_get_main_queue(),^{VTAttachForced=true;VTAttach();});
}
__attribute__((constructor)) static void VTBootstrap(){
    dispatch_async(dispatch_get_main_queue(),^{
        VTLaunchTime=CACurrentMediaTime();
        if(VTSafeBootRequested()){VTLog(@"safe boot: dylib loaded, menu inert");return;}
        vt::installLoginProbe();
        VTLog(@"loaded, attach delay %.1fs",double(VTAttachDelay()));
        NSNotificationCenter*c=NSNotificationCenter.defaultCenter;
        [c addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification*n){VTAttach();}];
        [c addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification*n){[VTController setRenderingActive:NO];if(VTController&&VTController.view)VTController.view.hidden=YES;}];
        [c addObserverForName:UISceneDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification*n){if(n.object==VTHostScene)VTDetach();}];
        VTHostTimer=[NSTimer scheduledTimerWithTimeInterval:.5 repeats:YES block:^(NSTimer*t){VTAttach();}];
        VTAttach();
    });
}

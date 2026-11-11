/*****************************************************************************
 * VLCPictureInPictureController.m: macOS Picture in Picture support
 *****************************************************************************
 * Copyright (C) 2026 VLC authors and VideoLAN
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston MA 02110-1301, USA.
 *****************************************************************************/

#import "VLCPictureInPictureController.h"

#import "PIPSPI.h"
#import "VLCMain.h"
#import "VLCMainWindow.h"
#import "VLCCoreInteraction.h"
#import "VLCVoutView.h"
#import "VLCVoutWindowController.h"
#import "Windows.h"

#import <QuartzCore/QuartzCore.h>

NSString *const VLCPictureInPictureStateChangedNotification = @"VLCPictureInPictureStateChangedNotification";

static NSString *const VLCPIPFrameworkPath = @"/System/Library/PrivateFrameworks/PIP.framework";
static const NSTimeInterval VLCPIPFullscreenExitPollInterval = 0.05;
static const NSTimeInterval VLCPIPFullscreenExitTimeout = 5.0;
static const NSTimeInterval VLCPIPPresentationSettleDelay = 0.15;
static const NSTimeInterval VLCPIPDismissalDelay = 0.05;
static const NSTimeInterval VLCPIPWatchdogInterval = 4.0;

static BOOL ConstraintItemIsAttached(id item, NSView *owner)
{
    return ![item isKindOfClass:[NSView class]] || [(NSView *)item isDescendantOf:owner];
}

@interface VLCPictureInPictureHostView : NSView
@end

@implementation VLCPictureInPictureHostView

- (instancetype)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (self) {
        self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        self.wantsLayer = YES;
        self.layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    }
    return self;
}

- (BOOL)isOpaque
{
    return YES;
}

@end

@interface VLCPictureInPicturePlaceholderView : NSView
@property (nonatomic, copy) void (^clickHandler)(void);
@property (nonatomic, copy) void (^keyHandler)(NSEvent *event);
@end

@implementation VLCPictureInPicturePlaceholderView
{
    NSTextField *_titleLabel;
    NSTextField *_detailLabel;
}

- (instancetype)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
        _titleLabel = [self makeLabel:_NS("Playing in Picture in Picture")
                             fontSize:15.
                                color:[NSColor colorWithCalibratedWhite:0.85 alpha:1.]];
        _detailLabel = [self makeLabel:_NS("Click here to bring the video back to this window")
                              fontSize:12.
                                 color:[NSColor colorWithCalibratedWhite:0.55 alpha:1.]];
        [self layoutLabels];
    }
    return self;
}

- (NSTextField *)makeLabel:(NSString *)text fontSize:(CGFloat)fontSize color:(NSColor *)color
{
    NSTextField *label = [[NSTextField alloc] initWithFrame:NSZeroRect];
    label.stringValue = text;
    label.font = [NSFont systemFontOfSize:fontSize];
    label.textColor = color;
    label.alignment = NSTextAlignmentCenter;
    label.bezeled = NO;
    label.bordered = NO;
    label.editable = NO;
    label.selectable = NO;
    label.drawsBackground = NO;
    [label sizeToFit];
    [self addSubview:label];
    return label;
}

- (void)layoutLabels
{
    NSRect bounds = self.bounds;
    CGFloat spacing = 6.;
    CGFloat totalHeight = NSHeight(_titleLabel.frame) + spacing + NSHeight(_detailLabel.frame);
    CGFloat top = NSMidY(bounds) + totalHeight / 2.;

    NSRect titleFrame = _titleLabel.frame;
    titleFrame.origin.x = NSMidX(bounds) - NSWidth(titleFrame) / 2.;
    titleFrame.origin.y = top - NSHeight(titleFrame);
    _titleLabel.frame = NSIntegralRect(titleFrame);

    NSRect detailFrame = _detailLabel.frame;
    detailFrame.origin.x = NSMidX(bounds) - NSWidth(detailFrame) / 2.;
    detailFrame.origin.y = NSMinY(_titleLabel.frame) - spacing - NSHeight(detailFrame);
    _detailLabel.frame = NSIntegralRect(detailFrame);

    _detailLabel.hidden = NSHeight(bounds) < totalHeight + 20. || NSWidth(bounds) < NSWidth(detailFrame) + 20.;
    _titleLabel.hidden = NSWidth(bounds) < NSWidth(titleFrame) + 20.;
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize
{
    [super resizeSubviewsWithOldSize:oldSize];
    [self layoutLabels];
}

- (void)mouseDown:(NSEvent *)event
{
    if (self.clickHandler)
        self.clickHandler();
}

- (void)keyDown:(NSEvent *)event
{
    if (self.keyHandler)
        self.keyHandler(event);
    else
        [super keyDown:event];
}

- (BOOL)acceptsFirstResponder
{
    return YES;
}

- (BOOL)mouseDownCanMoveWindow
{
    return NO;
}

- (BOOL)isOpaque
{
    return YES;
}

@end

@interface VLCPictureInPictureController () <PIPViewControllerDelegate>
{
    PIPViewController *_pipViewController;
    NSViewController *_hostViewController;
    VLCPictureInPictureHostView *_hostView;
    VLCPictureInPicturePlaceholderView *_placeholderView;
    VLCVoutView *_videoView;
    NSAutoresizingMaskOptions _videoViewAutoresizingMask;
    BOOL _videoViewTranslatesAutoresizingMask;
    NSMutableArray<NSDictionary *> *_savedConstraints;

    BOOL _presented;
    BOOL _pendingDismissal;
    BOOL _dismissing;
    BOOL _suppressActivation;
    BOOL _nativeVideoSizeChanged;
    CFTimeInterval _presentedTime;
    NSTimer *_watchdog;

    NSTimer *_fullscreenExitTimer;
    NSDate *_fullscreenExitDeadline;
    BOOL _fullscreenExitRequested;
    __weak VLCVideoWindowCommon *_pendingWindow;
    __weak VLCVideoWindowCommon *_queuedWindow;
}

@property (readwrite, weak) VLCVideoWindowCommon *videoWindow;

@end

@implementation VLCPictureInPictureController

+ (instancetype)sharedInstance
{
    static VLCPictureInPictureController *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[VLCPictureInPictureController alloc] init];
    });
    return sharedInstance;
}

+ (Class)pipViewControllerClass
{
    static Class pipClass = Nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSBundle *bundle = [NSBundle bundleWithPath:VLCPIPFrameworkPath];
        if ([bundle load])
            pipClass = NSClassFromString(@"PIPViewController");
        if (!pipClass)
            msg_Warn(getIntf(), "Picture in Picture is unavailable: PIP.framework could not be loaded");
    });
    return pipClass;
}

+ (BOOL)isSupported
{
    if (@available(macOS 10.12, *))
        return [self pipViewControllerClass] != Nil;
    return NO;
}

- (BOOL)isActive
{
    return _pipViewController != nil;
}

- (void)togglePictureInPicture
{
    if (self.isActive) {
        [self exitPictureInPicture];
        return;
    }

    VLCVideoWindowCommon *window = [self preferredVideoWindow];
    if (window)
        [self enterPictureInPictureForWindow:window];
}

- (VLCVideoWindowCommon *)preferredVideoWindow
{
    NSWindow *keyWindow = [NSApp keyWindow];
    if ([keyWindow isKindOfClass:[VLCVideoWindowCommon class]] && [(VLCVideoWindowCommon *)keyWindow hasActiveVideo])
        return (VLCVideoWindowCommon *)keyWindow;

    __block VLCVideoWindowCommon *candidate = nil;
    [[[VLCMain sharedInstance] voutController] updateWindowsUsingBlock:^(VLCVideoWindowCommon *window) {
        if (![window hasActiveVideo])
            return;
        if (!candidate || [window isKindOfClass:[VLCMainWindow class]])
            candidate = window;
    }];
    return candidate;
}

- (NSMutableArray<NSDictionary *> *)constraintsReferencingView:(NSView *)view
{
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (NSView *ancestor = [view superview]; ancestor; ancestor = [ancestor superview]) {
        for (NSLayoutConstraint *constraint in [ancestor constraints]) {
            if (constraint.firstItem == view || constraint.secondItem == view)
                [entries addObject:@{ @"owner": ancestor, @"constraint": constraint }];
        }
    }
    return entries;
}

- (void)enterPictureInPictureForWindow:(VLCVideoWindowCommon *)window
{
    if (!window || ![[self class] isSupported])
        return;

    if (self.isActive) {
        if (_dismissing)
            _queuedWindow = window;
        return;
    }

    if (![window hasActiveVideo])
        return;

    if ([window fullscreen] || [window inFullscreenTransition]) {
        [self leaveFullscreenThenEnterPictureInPictureForWindow:window];
        return;
    }
    [self cancelPendingFullscreenExit];

    VLCVoutView *videoView = [window videoView];
    NSView *superview = [videoView superview];
    if (!videoView || !superview) {
        msg_Warn(getIntf(), "refusing Picture in Picture: video view is not attached to its window");
        return;
    }

    Class pipClass = [[self class] pipViewControllerClass];
    NSRect videoFrame = [videoView frame];
    NSResponder *firstResponder = [window firstResponder];
    BOOL videoHadFocus = [firstResponder isKindOfClass:[NSView class]] && [(NSView *)firstResponder isDescendantOf:videoView];

    _videoView = videoView;
    self.videoWindow = window;
    _videoViewAutoresizingMask = [videoView autoresizingMask];
    _videoViewTranslatesAutoresizingMask = [videoView translatesAutoresizingMaskIntoConstraints];
    _savedConstraints = _videoViewTranslatesAutoresizingMask ? nil : [self constraintsReferencingView:videoView];
    _presented = NO;
    _pendingDismissal = NO;
    _dismissing = NO;
    _suppressActivation = NO;
    _nativeVideoSizeChanged = NO;

    __weak typeof(self) weakSelf = self;
    __weak VLCVoutView *weakVideoView = videoView;

    _placeholderView = [[VLCPictureInPicturePlaceholderView alloc] initWithFrame:videoFrame];
    [_placeholderView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    _placeholderView.clickHandler = ^{
        [weakSelf exitPictureInPicture];
    };
    _placeholderView.keyHandler = ^(NSEvent *event) {
        [weakVideoView keyDown:event];
    };

    _hostView = [[VLCPictureInPictureHostView alloc] initWithFrame:NSMakeRect(0., 0., NSWidth(videoFrame), NSHeight(videoFrame))];
    _hostViewController = [[NSViewController alloc] init];
    [_hostViewController setView:_hostView];

    _pipViewController = [[pipClass alloc] init];
    [_pipViewController setDelegate:self];
    [_pipViewController setUserCanResize:YES];
    [_pipViewController setTitle:[window title]];
    [_pipViewController setAspectRatio:[self aspectRatioForWindow:window fallback:videoFrame.size]];
    [_pipViewController setPlaying:[self isPlaying]];
    [_pipViewController setReplacementWindow:window];
    [_pipViewController setReplacementRect:[superview convertRect:videoFrame toView:nil]];

    videoView.translatesAutoresizingMaskIntoConstraints = YES;

    NSDisableScreenUpdates();
    [superview replaceSubview:videoView with:_placeholderView];
    [_placeholderView setFrame:videoFrame];
    [_hostView addSubview:videoView];
    [videoView setFrame:[_hostView bounds]];
    [videoView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [videoView setHidden:NO];
    NSEnableScreenUpdates();

    if (videoHadFocus)
        [window makeFirstResponder:_placeholderView];

    [window setInPictureInPicture:YES];
    [self presentHostViewController];
    [self reshapeVideoOutputViews];
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf reshapeVideoOutputViews];
    });

    msg_Dbg(getIntf(), "entered Picture in Picture");
    [[NSNotificationCenter defaultCenter] postNotificationName:VLCPictureInPictureStateChangedNotification object:self];
}

- (void)exitPictureInPicture
{
    if (!self.isActive || _dismissing)
        return;
    _dismissing = YES;
    [self dismissHostViewController];
}

- (void)videoWindowWillRemoveVout:(VLCVideoWindowCommon *)window
{
    if (window == _pendingWindow)
        [self cancelPendingFullscreenExit];
    if (window == _queuedWindow)
        _queuedWindow = nil;
    if (!self.isActive || window != self.videoWindow)
        return;

    msg_Dbg(getIntf(), "leaving Picture in Picture: video output is closing");
    _suppressActivation = YES;
    [self restoreVideoView];
    [self exitPictureInPicture];
}

- (void)videoWindowWillEnterFullscreen:(VLCVideoWindowCommon *)window
{
    if (!self.isActive || window != self.videoWindow)
        return;

    msg_Dbg(getIntf(), "leaving Picture in Picture: window enters fullscreen");
    _suppressActivation = YES;
    _nativeVideoSizeChanged = NO;
    [self restoreVideoView];
    [self exitPictureInPicture];
}

- (void)videoWindow:(VLCVideoWindowCommon *)window nativeVideoSizeChanged:(NSSize)size
{
    if (!self.isActive || window != self.videoWindow)
        return;

    _nativeVideoSizeChanged = YES;
    if (size.width > 0. && size.height > 0.)
        [_pipViewController setAspectRatio:size];
}

- (void)playbackStateChanged
{
    if (!self.isActive)
        return;
    [_pipViewController setPlaying:[self isPlaying]];
}

- (void)presentHostViewController
{
    PIPViewController *pip = _pipViewController;
    __weak typeof(self) weakSelf = self;
    void (^completion)(void) = ^{
        [weakSelf presentationCompletedForController:pip];
    };

    if ([pip respondsToSelector:@selector(presentViewControllerAsPictureInPicture:completionHandler:)]) {
        [pip presentViewControllerAsPictureInPicture:_hostViewController completionHandler:completion];
    } else {
        [pip presentViewControllerAsPictureInPicture:_hostViewController];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VLCPIPPresentationSettleDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), completion);
    }
    [self armWatchdog];
}

- (void)presentationCompletedForController:(PIPViewController *)pip
{
    if (!pip || pip != _pipViewController || _presented)
        return;

    _presented = YES;
    _presentedTime = CACurrentMediaTime();
    if (_pendingDismissal) {
        _pendingDismissal = NO;
        [self dismissHostViewController];
    } else {
        [self disarmWatchdog];
    }
}

- (void)dismissHostViewController
{
    if (!_presented) {
        _pendingDismissal = YES;
        return;
    }

    PIPViewController *pip = _pipViewController;
    NSTimeInterval wait = VLCPIPDismissalDelay - (CACurrentMediaTime() - _presentedTime);
    if (wait <= 0.) {
        [self dismissPresentedController:pip];
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf dismissPresentedController:pip];
    });
}

- (void)dismissPresentedController:(PIPViewController *)pip
{
    if (!pip || pip != _pipViewController)
        return;

    [self armWatchdog];
    if (@available(macOS 10.10, *))
        [pip dismissViewController:_hostViewController];
}

- (void)armWatchdog
{
    [_watchdog invalidate];
    _watchdog = [NSTimer scheduledTimerWithTimeInterval:VLCPIPWatchdogInterval
                                                 target:self
                                               selector:@selector(watchdogFired:)
                                               userInfo:nil
                                                repeats:NO];
}

- (void)disarmWatchdog
{
    [_watchdog invalidate];
    _watchdog = nil;
}

- (void)watchdogFired:(NSTimer *)timer
{
    _watchdog = nil;
    if (!self.isActive)
        return;

    if (!_presented) {
        [self presentationCompletedForController:_pipViewController];
        return;
    }

    if (_dismissing) {
        msg_Warn(getIntf(), "Picture in Picture did not close in time, resetting");
        [self finishPictureInPicture];
    }
}

- (void)restoreVideoView
{
    VLCVoutView *videoView = _videoView;
    if (!videoView)
        return;

    VLCVideoWindowCommon *window = self.videoWindow;
    VLCPictureInPicturePlaceholderView *placeholder = _placeholderView;
    NSView *placeholderSuperview = [placeholder superview];

    NSDisableScreenUpdates();
    [videoView removeFromSuperviewWithoutNeedingDisplay];
    if (placeholderSuperview) {
        [placeholderSuperview replaceSubview:placeholder with:videoView];
        [videoView setFrame:[placeholder frame]];
        [videoView setAutoresizingMask:_videoViewAutoresizingMask];
        videoView.translatesAutoresizingMaskIntoConstraints = _videoViewTranslatesAutoresizingMask;
        for (NSDictionary *entry in _savedConstraints) {
            NSView *owner = [entry objectForKey:@"owner"];
            NSLayoutConstraint *constraint = [entry objectForKey:@"constraint"];
            if ([[owner constraints] containsObject:constraint])
                continue;
            if (!ConstraintItemIsAttached(constraint.firstItem, owner) || !ConstraintItemIsAttached(constraint.secondItem, owner))
                continue;
            [owner addConstraint:constraint];
        }
        [videoView setHidden:[window videoViewHiddenAfterPictureInPicture]];
    } else {
        [placeholder removeFromSuperview];
    }

    NSView *outputView = [[videoView subviews] firstObject];
    if (outputView && ![videoView isHidden] && [videoView window])
        [[videoView window] makeFirstResponder:outputView];
    NSEnableScreenUpdates();

    [self reshapeVideoOutputViews];
    [window setInPictureInPicture:NO];
    if (_nativeVideoSizeChanged && [window hasActiveVideo])
        [window setNativeVideoSize:[window nativeVideoSize]];

    _videoView = nil;
    _placeholderView = nil;
    _savedConstraints = nil;
    _nativeVideoSizeChanged = NO;
}

- (void)finishPictureInPicture
{
    [self disarmWatchdog];
    [self restoreVideoView];
    [_pipViewController setDelegate:nil];
    _pipViewController = nil;
    _hostViewController = nil;
    _hostView = nil;
    self.videoWindow = nil;
    _presented = NO;
    _pendingDismissal = NO;
    _dismissing = NO;
    _suppressActivation = NO;

    msg_Dbg(getIntf(), "left Picture in Picture");
    [[NSNotificationCenter defaultCenter] postNotificationName:VLCPictureInPictureStateChangedNotification object:self];

    VLCVideoWindowCommon *queued = _queuedWindow;
    _queuedWindow = nil;
    if (queued && [queued hasActiveVideo]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self enterPictureInPictureForWindow:queued];
        });
    }
}

- (void)reshapeVideoOutputViews
{
    for (NSView *subview in [_videoView subviews]) {
        if ([subview respondsToSelector:@selector(reshape)])
            [(NSOpenGLView *)subview reshape];
    }
}

- (BOOL)isPlaying
{
    intf_thread_t *p_intf = getIntf();
    if (!p_intf)
        return NO;

    input_thread_t *p_input = pl_CurrentInput(p_intf);
    if (!p_input)
        return NO;

    input_state_e state = var_GetInteger(p_input, "state");
    vlc_object_release(p_input);
    return state == PLAYING_S || state == OPENING_S;
}

- (NSSize)aspectRatioForWindow:(VLCVideoWindowCommon *)window fallback:(NSSize)fallback
{
    NSSize nativeSize = [window nativeVideoSize];
    if (nativeSize.width > 0. && nativeSize.height > 0.)
        return nativeSize;
    if (fallback.width > 0. && fallback.height > 0.)
        return fallback;
    return NSMakeSize(16., 9.);
}

- (void)leaveFullscreenThenEnterPictureInPictureForWindow:(VLCVideoWindowCommon *)window
{
    if (_fullscreenExitTimer)
        return;

    msg_Dbg(getIntf(), "leaving fullscreen before entering Picture in Picture");
    _pendingWindow = window;
    _fullscreenExitRequested = NO;
    _fullscreenExitDeadline = [NSDate dateWithTimeIntervalSinceNow:VLCPIPFullscreenExitTimeout];
    _fullscreenExitTimer = [NSTimer scheduledTimerWithTimeInterval:VLCPIPFullscreenExitPollInterval
                                                            target:self
                                                          selector:@selector(pollFullscreenExit:)
                                                          userInfo:nil
                                                           repeats:YES];
    [self pollFullscreenExit:_fullscreenExitTimer];
}

- (void)requestFullscreenExitForWindow:(VLCVideoWindowCommon *)window
{
    vout_thread_t *p_vout = [[window videoView] voutThread];
    if (p_vout) {
        var_SetBool(p_vout, "fullscreen", false);
        vlc_object_release(p_vout);
    }
    var_SetBool(pl_Get(getIntf()), "fullscreen", false);
}

- (void)pollFullscreenExit:(NSTimer *)timer
{
    VLCVideoWindowCommon *window = _pendingWindow;
    if (!window) {
        [self cancelPendingFullscreenExit];
        return;
    }

    BOOL transitioning = [window inFullscreenTransition];
    if (transitioning || [window fullscreen]) {
        if ([[NSDate date] compare:_fullscreenExitDeadline] != NSOrderedAscending) {
            [self cancelPendingFullscreenExit];
            msg_Warn(getIntf(), "giving up on Picture in Picture: window did not leave fullscreen");
            return;
        }
        if (!transitioning && !_fullscreenExitRequested) {
            _fullscreenExitRequested = YES;
            [self requestFullscreenExitForWindow:window];
        }
        return;
    }

    [self cancelPendingFullscreenExit];
    [self enterPictureInPictureForWindow:window];
}

- (void)cancelPendingFullscreenExit
{
    [_fullscreenExitTimer invalidate];
    _fullscreenExitTimer = nil;
    _fullscreenExitDeadline = nil;
    _fullscreenExitRequested = NO;
    _pendingWindow = nil;
}

- (BOOL)pipShouldClose:(PIPViewController *)pip
{
    return YES;
}

- (void)pipWillClose:(PIPViewController *)pip
{
    if (pip != _pipViewController)
        return;

    _dismissing = YES;

    VLCVideoWindowCommon *window = self.videoWindow;
    NSView *placeholderSuperview = [_placeholderView superview];
    if (!window || !placeholderSuperview)
        return;

    [pip setReplacementWindow:window];
    [pip setReplacementRect:[placeholderSuperview convertRect:[_placeholderView frame] toView:nil]];
    if (_suppressActivation)
        return;

    if ([window isMiniaturized])
        [window deminiaturize:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [window makeKeyAndOrderFront:nil];
}

- (void)pipDidClose:(PIPViewController *)pip
{
    if (pip != _pipViewController)
        return;
    [self finishPictureInPicture];
}

- (void)pipActionPlay:(PIPViewController *)pip
{
    [[VLCCoreInteraction sharedInstance] play];
}

- (void)pipActionPause:(PIPViewController *)pip
{
    [[VLCCoreInteraction sharedInstance] pause];
}

- (void)pipActionStop:(PIPViewController *)pip
{
    _suppressActivation = YES;
    [[VLCCoreInteraction sharedInstance] pause];
}

@end

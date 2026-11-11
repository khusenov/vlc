/*****************************************************************************
 * VLCPictureInPictureController.h: macOS Picture in Picture support
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

#import <Cocoa/Cocoa.h>

@class VLCVideoWindowCommon;

extern NSString *const VLCPictureInPictureStateChangedNotification;

@interface VLCPictureInPictureController : NSObject

+ (instancetype)sharedInstance;
+ (BOOL)isSupported;

@property (readonly) BOOL isActive;
@property (readonly, weak) VLCVideoWindowCommon *videoWindow;

- (void)togglePictureInPicture;
- (void)enterPictureInPictureForWindow:(VLCVideoWindowCommon *)window;
- (void)exitPictureInPicture;

- (void)videoWindowWillRemoveVout:(VLCVideoWindowCommon *)window;
- (void)videoWindowWillEnterFullscreen:(VLCVideoWindowCommon *)window;
- (void)videoWindow:(VLCVideoWindowCommon *)window nativeVideoSizeChanged:(NSSize)size;
- (void)playbackStateChanged;

@end

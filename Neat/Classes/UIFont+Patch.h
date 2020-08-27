//
//  UIFont+Patch.h
//  Pods
//
//  Created by Gao on 4/8/17.
//
//

#import "TargetConditionals.h"

#if TARGET_OS_OSX
#import <Cocoa/Cocoa.h>
#define Font NSFont
#else
#import <UIKit/UIKit.h>
#define Font UIFont
#endif

@interface Font(Patch)

+ (void)patchMetrics;


#if DEBUG
+ (void)unpatch;
#endif

@end

#import <UIKit/UIKit.h>

#include "ios_platform.h"

#include <SDL.h>

#include <cmath>
#include <cstring>

@interface PvzAlertDelegate : NSObject<UIAlertViewDelegate>
@property (nonatomic, assign) BOOL dismissed;
@end

@implementation PvzAlertDelegate

- (void)alertView:(UIAlertView*)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
	(void)alertView;
	(void)buttonIndex;
	self.dismissed = YES;
}

- (void)alertView:(UIAlertView*)alertView didDismissWithButtonIndex:(NSInteger)buttonIndex
{
	(void)alertView;
	(void)buttonIndex;
	self.dismissed = YES;
}

@end

static void iOS_ShowBlockingAlertOnMainThread(const char* title, const char* message)
{
	@autoreleasepool {
		PvzAlertDelegate* delegate = [[PvzAlertDelegate alloc] init];
		delegate.dismissed = NO;

		NSString* nsTitle = title ? [NSString stringWithUTF8String:title] : @"PvZ Portable";
		NSString* nsMessage = message ? [NSString stringWithUTF8String:message] : @"";

		UIAlertView* alert = [[UIAlertView alloc] initWithTitle:nsTitle
		                                                message:nsMessage
		                                               delegate:delegate
		                                      cancelButtonTitle:@"OK"
		                                      otherButtonTitles:nil];
		[alert show];

		while (!delegate.dismissed)
		{
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
			                         beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
		}
	}
}

extern "C" bool iOS_GetDocumentsPath(char* outPath, size_t outPathSize)
{
	if (outPath == nullptr || outPathSize == 0)
		return false;

	outPath[0] = '\0';

	@autoreleasepool {
		NSArray* paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
		if (paths.count == 0)
			return false;

		NSString* docs = paths[0];
		if (docs.length == 0)
			return false;

		const char* utf8 = docs.UTF8String;
		if (utf8 == nullptr || utf8[0] == '\0')
			return false;

		strncpy(outPath, utf8, outPathSize - 1);
		outPath[outPathSize - 1] = '\0';
		return true;
	}
}

extern "C" void iOS_ShowBlockingAlert(const char* title, const char* message)
{
	if ([NSThread isMainThread])
	{
		iOS_ShowBlockingAlertOnMainThread(title, message);
		return;
	}

	dispatch_sync(dispatch_get_main_queue(), ^{
		iOS_ShowBlockingAlertOnMainThread(title, message);
	});
}

extern "C" bool iOS_WaitForValidScreenBounds(int* outW, int* outH, int maxWaitMs)
{
	const int stepMs = 50;
	int waited = 0;

	while (waited < maxWaitMs)
	{
		@autoreleasepool {
			CGRect bounds = [UIScreen mainScreen].bounds;
			if (bounds.size.width > 0.0f && bounds.size.height > 0.0f &&
				!std::isnan(bounds.size.width) && !std::isnan(bounds.size.height))
			{
				if (outW != nullptr)
					*outW = (int)bounds.size.width;
				if (outH != nullptr)
					*outH = (int)bounds.size.height;
				return true;
			}
		}

		SDL_Delay(stepMs);
		SDL_PumpEvents();
		waited += stepMs;
	}

	if (outW != nullptr)
		*outW = 1024;
	if (outH != nullptr)
		*outH = 768;
	return false;
}

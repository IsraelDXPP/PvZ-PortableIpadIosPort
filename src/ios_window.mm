#import <UIKit/UIKit.h>

#include <SDL.h>

#include <cmath>

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

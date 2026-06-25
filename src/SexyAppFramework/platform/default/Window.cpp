/*
 * Portions of this file are based on the PopCap Games Framework
 * Copyright (C) 2005-2009 PopCap Games, Inc.
 * 
 * Copyright (C) 2026 Zhou Qiankang <wszqkzqk@qq.com>
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later AND LicenseRef-PopCap
 *
 * This file is part of PvZ-Portable.
 *
 * PvZ-Portable is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * PvZ-Portable is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with PvZ-Portable. If not, see <https://www.gnu.org/licenses/>.
 */

#include <SDL.h>

#include "SexyAppBase.h"
#include "graphics/GLInterface.h"
#include "graphics/GLImage.h"
#include "graphics/GLPlatform.h"
#include "widget/WidgetManager.h"

#ifndef SDL_HINT_APP_ID // SDL2 compatibility (already defined in SDL3.2+)
#define SDL_HINT_APP_ID "SDL_APP_ID"
#endif

using namespace Sexy;

#ifdef __IPHONEOS__
#include "ios_platform.h"
#endif

void SexyAppBase::MakeWindow()
{
	if (mWindow)
	{
		SDL_SetWindowFullscreen((SDL_Window*)mWindow, (!mIsWindowed ? SDL_WINDOW_FULLSCREEN_DESKTOP : 0));
	}
	else
	{
		// For Wayland's icon support on the game window
		SDL_SetHint(SDL_HINT_APP_ID, "io.github.wszqkzqk.pvz-portable");

#if (defined(__ANDROID__) && !defined(__TERMUX__)) || defined(__IPHONEOS__)
		SDL_SetHint(SDL_HINT_ORIENTATIONS, "LandscapeLeft LandscapeRight");
#endif

		SDL_Init(SDL_INIT_VIDEO);

#ifdef __IPHONEOS__
		// --- iOS window strategy ---
		// Root problem: SDL_CreateWindow on iOS 9 iPad with an explicit position (even 0,0)
		// causes UIKit to set a CALayer frame that may contain NaN when UIScreen.bounds is
		// not yet settled.  The resulting CALayerInvalidGeometry NSException propagates
		// through the SjLj C++ unwinder (armv7 / -fsjlj-exceptions) and hits __cxa_bad_cast
		// → abort(), with no visible error.
		//
		// Fix:
		//  1. SDL_WINDOWPOS_UNDEFINED — let UIKit own the position completely.
		//  2. SDL_WINDOW_FULLSCREEN_DESKTOP — SDL does NOT set an explicit CALayer frame;
		//     UIKit stretches it to the screen automatically.
		//  3. Wait for valid UIScreen bounds so we have real render dimensions.
		//  4. Wrap SDL_CreateWindow in @try/@catch to catch CALayerInvalidGeometry
		//     before it escapes into SjLj territory and causes an unrecoverable abort.

		// Wait up to 3 s for UIScreen to have valid bounds (avoids NaN in UIKit)
		int displayW = 0;
		int displayH = 0;
		iOS_WaitForValidScreenBounds(&displayW, &displayH, 100);

		// Also ask SDL for the display mode (may be more reliable after SDL_Init)
		SDL_DisplayMode displayMode;
		if (SDL_GetCurrentDisplayMode(0, &displayMode) == 0 &&
			displayMode.w > 0 && displayMode.h > 0)
		{
			displayW = displayMode.w;
			displayH = displayMode.h;
		}

		// Failsafe
		if (displayW <= 0 || displayH <= 0) {
			displayW = 1024;
			displayH = 768;
		}

		// Use FULLSCREEN_DESKTOP: SDL defers the CALayer frame to UIKit entirely.
		// Do NOT use SDL_WINDOW_FULLSCREEN — it passes explicit w/h to UIKit_CreateWindow
		// which can produce a NaN CALayer position on iOS 9 before bounds are settled.
		Uint32 winFlags = SDL_WINDOW_OPENGL | SDL_WINDOW_FULLSCREEN_DESKTOP | SDL_WINDOW_SHOWN;
		// UNDEFINED position: never pass 0,0 explicitly on iOS.
		int winX = SDL_WINDOWPOS_UNDEFINED;
		int winY = SDL_WINDOWPOS_UNDEFINED;
		// Pass the display size — SDL will use this as a hint but FULLSCREEN_DESKTOP
		// overrides it from the screen anyway.
		int winW = displayW;
		int winH = displayH;
#else
		Uint32 winFlags = SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE
			| (!mIsWindowed ? SDL_WINDOW_FULLSCREEN_DESKTOP : 0);
		int winX = SDL_WINDOWPOS_CENTERED;
		int winY = SDL_WINDOWPOS_CENTERED;
		int winW = mWidth * IMG_DOWNSCALE;
		int winH = mHeight * IMG_DOWNSCALE;
#endif

		// Try OpenGL ES 2.0 first (Linux, most Windows drivers, ANGLE, etc.)
		SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES);
		SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 2);
		SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);

#ifdef __IPHONEOS__
		mWindow = (void*)iOS_CreateWindowSafe(
			mTitle.c_str(),
			winX, winY,
			winW, winH, winFlags);
#else
		mWindow = (void*)SDL_CreateWindow(
			mTitle.c_str(),
			winX, winY,
			winW, winH, winFlags);
#endif

		if (mWindow) {
#ifdef __IPHONEOS__
			mContext = (void*)iOS_CreateGLContextSafe((SDL_Window*)mWindow);
#else
			mContext = (void*)SDL_GL_CreateContext((SDL_Window*)mWindow);
#endif
		}

#if defined(__ANDROID__) || defined(__IPHONEOS__)
		// EGL/EAGL surface may be transiently unavailable on mobile
		for (int retry = 0; !mContext && mWindow && retry < 20; retry++)
		{
			SDL_Delay(100);
			SDL_PumpEvents();
#ifdef __IPHONEOS__
			mContext = (void*)iOS_CreateGLContextSafe((SDL_Window*)mWindow);
#else
			mContext = (void*)SDL_GL_CreateContext((SDL_Window*)mWindow);
#endif
		}
		if (!mContext)
		{
			if (mWindow) { SDL_DestroyWindow((SDL_Window*)mWindow); mWindow = nullptr; }
			fprintf(stderr, "Failed to create OpenGL ES context.\n");
			return;
		}
#else
		// Fallback: desktop GL 2.1 compatibility (macOS, old Windows drivers, etc.)
		if (!mContext)
		{
			if (mWindow) { SDL_DestroyWindow((SDL_Window*)mWindow); mWindow = nullptr; }

			SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_COMPATIBILITY);
			SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 2);
			SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 1);

			mWindow = (void*)SDL_CreateWindow(
				mTitle.c_str(),
				SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
				mWidth * IMG_DOWNSCALE, mHeight * IMG_DOWNSCALE, winFlags);

			if (mWindow)
				mContext = (void*)SDL_GL_CreateContext((SDL_Window*)mWindow);

			if (!mContext)
			{
				if (mWindow) { SDL_DestroyWindow((SDL_Window*)mWindow); mWindow = nullptr; }
				fprintf(stderr, "Failed to create any OpenGL context. "
					"Please check your graphics drivers.\n");
				return;
			}

			gDesktopGLFallback = true;
		}
#endif

		SDL_GL_SetSwapInterval(1);
	}

	if (mGLInterface == nullptr)
	{
		mGLInterface = new GLInterface(this);
		if (!InitGLInterface())
		{
			delete mGLInterface;
			mGLInterface = nullptr;
			return;
		}
	}

	bool isActive = mActive;
	mActive = !!(SDL_GetWindowFlags((SDL_Window*)mWindow) & SDL_WINDOW_INPUT_FOCUS);

	mPhysMinimized = false;
	if (mMinimized)
	{
		if (mMuteOnLostFocus)
			Unmute(true);

		mMinimized = false;
		isActive = mActive; // set this here so we don't call RehupFocus again.
		RehupFocus();
	}
	
	if (isActive != mActive)
		RehupFocus();

	ReInitImages();

	mWidgetManager->mImage = mGLInterface->GetScreenImage();
	mWidgetManager->MarkAllDirty();

	mGLInterface->UpdateViewport();
	mWidgetManager->Resize(mScreenBounds, mGLInterface->mPresentationRect);
}

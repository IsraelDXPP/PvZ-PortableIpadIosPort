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
extern "C" bool iOS_WaitForValidScreenBounds(int* outW, int* outH, int maxWaitMs);
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
		// On iOS, explicit dimensions and 0,0 position to avoid CALayer NaN exceptions
		// on older iOS versions (iOS 9) when screen bounds aren't fully resolved yet.
		// iPad is especially sensitive: without a launch storyboard or before UIKit settles,
		// UIScreen bounds can be invalid and UIKit_CreateWindow throws CALayerInvalidGeometry.
		int displayW = 0;
		int displayH = 0;
		iOS_WaitForValidScreenBounds(&displayW, &displayH, 3000);

		SDL_DisplayMode displayMode;
		if (SDL_GetCurrentDisplayMode(0, &displayMode) == 0 &&
			displayMode.w > 0 && displayMode.h > 0)
		{
			displayW = displayMode.w;
			displayH = displayMode.h;
		}

		Uint32 winFlags = SDL_WINDOW_OPENGL | SDL_WINDOW_FULLSCREEN | SDL_WINDOW_SHOWN;
		int winX = 0;
		int winY = 0;
		int winW = mWidth * IMG_DOWNSCALE;
		int winH = mHeight * IMG_DOWNSCALE;

		if (displayW > 0 && displayH > 0)
		{
			winW = displayW;
			winH = displayH;
		}

		// Failsafe bounds just in case SexyApp logic is not initialized yet
		if (winW <= 0 || winH <= 0) {
			winW = 1024;
			winH = 768;
		}
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

		mWindow = (void*)SDL_CreateWindow(
			mTitle.c_str(),
			winX, winY,
			winW, winH, winFlags);

		if (mWindow)
			mContext = (void*)SDL_GL_CreateContext((SDL_Window*)mWindow);

#if defined(__ANDROID__) || defined(__IPHONEOS__)
		// EGL/EAGL surface may be transiently unavailable on mobile
		for (int retry = 0; !mContext && mWindow && retry < 20; retry++)
		{
			SDL_Delay(100);
			SDL_PumpEvents();
			mContext = (void*)SDL_GL_CreateContext((SDL_Window*)mWindow);
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

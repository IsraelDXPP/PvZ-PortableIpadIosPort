/*
 * Copyright (C) 2026 Zhou Qiankang <wszqkzqk@qq.com>
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
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

#include "LawnApp.h"
#include "Resources.h"
#include "Sexy.TodLib/TodStringFile.h"
#include <cstdlib>
#include <fstream>
#include <system_error>

#include <vector>
using namespace Sexy;

#ifdef _WIN32
#include <windows.h>
#include <shellapi.h>
#endif

#ifdef __3DS__
#include <3ds.h>
#include <malloc.h>
extern "C" {
	unsigned int __stacksize__ = 512 * 1024;
}
#endif

#ifdef __IPHONEOS__
#include "ios_platform.h"
#include <SDL_hints.h>
extern void install_ios_exception_handler();
extern "C" int iOS_RunGameAfterActivation(int (*)(int, char**), int, char**);
#endif

#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#endif

bool (*gAppCloseRequest)();
bool (*gAppHasUsedCheatKeys)();
std::string (*gGetCurrentLevelName)();

#ifdef _WIN32
static std::vector<std::string> gUtf8ArgsStorage;
static std::vector<char*> gUtf8Argv;

static void BuildUtf8ArgsFromWin32(int& argc, char**& argv)
{
	int aWideArgc = 0;
	LPWSTR* aWideArgv = CommandLineToArgvW(GetCommandLineW(), &aWideArgc);
	if (aWideArgv == nullptr || aWideArgc <= 0)
		return;

	gUtf8ArgsStorage.clear();
	gUtf8Argv.clear();
	gUtf8ArgsStorage.reserve(static_cast<size_t>(aWideArgc));
	gUtf8Argv.reserve(static_cast<size_t>(aWideArgc));

	for (int i = 0; i < aWideArgc; ++i)
	{
		const wchar_t* aWide = aWideArgv[i];
		int aLen = WideCharToMultiByte(CP_UTF8, 0, aWide, -1, nullptr, 0, nullptr, nullptr);
		if (aLen <= 0)
		{
			gUtf8ArgsStorage.emplace_back();
		}
		else
		{
			std::string aUtf8;
			aUtf8.resize(static_cast<size_t>(aLen - 1));
			WideCharToMultiByte(CP_UTF8, 0, aWide, -1, aUtf8.data(), aLen, nullptr, nullptr);
			gUtf8ArgsStorage.emplace_back(std::move(aUtf8));
		}
	}

	for (auto& aStr : gUtf8ArgsStorage)
		gUtf8Argv.push_back(const_cast<char*>(aStr.c_str()));

	argc = static_cast<int>(gUtf8Argv.size());
	argv = gUtf8Argv.data();

	LocalFree(aWideArgv);
}
#endif

// Common game entry shared by all platforms.
static int run_game(int argc, char** argv)
{
	TodStringListSetColors(gLawnStringFormats, gLawnStringFormatCount);
	gGetCurrentLevelName = LawnGetCurrentLevelName;
	gAppCloseRequest = LawnGetCloseRequest;
	gAppHasUsedCheatKeys = LawnHasUsedCheatKeys;
	gExtractResourcesByName = Sexy::ExtractResourcesByName;
	gLawnApp = new LawnApp();
	gLawnApp->SetArgs(argc, argv);
	gLawnApp->Init();
	gLawnApp->Start();
#ifndef __EMSCRIPTEN__
	gLawnApp->Shutdown();
	if (gLawnApp)
		delete gLawnApp;
#endif
	return 0;
}

#ifdef __IPHONEOS__
// iOS entry point that checks resources, then starts the game.
// Everything runs inside iOS_RunWithExceptionCatch's @try/@catch.
static int ios_entry_point(int argc, char** argv)
{
	install_ios_exception_handler();

	// Permitir que el sistema arranque en cualquier orientación (Info.plist tiene
	// las 4), pero SDL solo considerará LandscapeLeft/LandscapeRight.
	// Esto evita que UIKit produzca geometría inconsistente durante la transición
	// de orientación al arrancar en portrait con una app landscape-only, lo que
	// disparaba "CALayer position contains NaN: [0 nan]" en iPad Mini 1 (iOS 9).
	SDL_SetHint(SDL_HINT_ORIENTATIONS, "LandscapeLeft LandscapeRight");

	char aDocsDir[512];
	const bool aHasDocsPath = iOS_GetDocumentsPath(aDocsDir, sizeof(aDocsDir));
	fs::path aDocsPath;
	bool aHasGameResources = false;

	// Log startup so we can confirm the binary actually ran
	iOS_WriteLogPublic("STARTUP", aHasDocsPath ? aDocsDir : "(no documents path)");

	if (aHasDocsPath)
	{
		aDocsPath = fs::path(aDocsDir);
		std::error_code ec;
		bool hasPak  = fs::is_regular_file(aDocsPath / "main.pak",    ec);
		bool hasProps = fs::is_directory  (aDocsPath / "properties",   ec);
		aHasGameResources = hasPak && hasProps;

		// Log individual asset presence for diagnostics
		iOS_WriteLogPublic("ASSETS", hasPak
			? (hasProps ? "main.pak=YES props=YES -> OK"
			            : "main.pak=YES props=MISSING")
			: (hasPak ? "main.pak=MISSING props=YES"
			            : "main.pak=MISSING props=MISSING"));
	}
	else
	{
		iOS_WriteLogPublic("ASSETS", "Could not determine Documents path");
	}

	if (!aHasGameResources)
	{
		const fs::path aReadmePath = aHasDocsPath ? (aDocsPath / "README.txt") : fs::path();
		if (aHasDocsPath)
		{
			std::error_code ec;
			if (!fs::exists(aReadmePath, ec))
			{
				std::ofstream(aReadmePath, std::ios::out | std::ios::trunc)
					<< "Place your `main.pak` and `properties/` folder here to play the game.\n";
			}
		}

		// iOS_ShowBlockingAlert always writes to pvz_log.txt first,
		// so this message is guaranteed to be recorded even if the UI
		// alert cannot be shown (e.g. before UIApplicationMain).
		iOS_ShowBlockingAlert(
			"Resources Not Found",
			"Please place main.pak and the properties/ folder into the "
			"PvZ Portable folder using the Files app or Finder/iTunes file sharing.\n\n"
			"The app will now exit.");
		return 1;
	}

	// Defer run_game() to the main queue.  This lets
	// applicationDidFinishLaunchingWithOptions: return so that
	// applicationDidBecomeActive: fires, making [UIScreen mainScreen].bounds
	// return valid dimensions when SDL_CreateWindow runs inside run_game().
	return iOS_RunGameAfterActivation(run_game, argc, argv);
}
#endif

int main(int argc, char** argv)
{
#ifdef __3DS__
	osSetSpeedupEnable(true);
#endif

#ifdef _WIN32
	BuildUtf8ArgsFromWin32(argc, argv);
#endif

#ifdef __IPHONEOS__
	// Wrap the entire game lifecycle in @try/@catch to prevent any ObjC
	// NSException from escaping into the SjLj C++ unwinder.
	return iOS_RunWithExceptionCatch(ios_entry_point, argc, argv);
#else
	return run_game(argc, argv);
#endif
};

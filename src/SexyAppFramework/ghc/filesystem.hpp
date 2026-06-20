//---------------------------------------------------------------------------------------
//
// ghc::filesystem - A C++17-like filesystem implementation for C++11/C++14/C++17/C++20
//
//---------------------------------------------------------------------------------------
//
// Copyright (c) 2018, Steffen Schümann <s.schuemann@pobox.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
//---------------------------------------------------------------------------------------
#ifndef GHC_FILESYSTEM_H
#define GHC_FILESYSTEM_H

// #define BSD manifest constant only in
// sys/param.h
#ifndef _WIN32
#include <sys/param.h>
#endif

#ifndef GHC_OS_DETECTED
#if defined(__APPLE__) && defined(__MACH__)
#define GHC_OS_APPLE
#elif defined(__linux__)
#define GHC_OS_LINUX
#if defined(__ANDROID__)
#define GHC_OS_ANDROID
#endif
#elif defined(_WIN64)
#define GHC_OS_WINDOWS
#define GHC_OS_WIN64
#elif defined(_WIN32)
#define GHC_OS_WINDOWS
#define GHC_OS_WIN32
#elif defined(__CYGWIN__)
#define GHC_OS_CYGWIN
#elif defined(__sun) && defined(__SVR4)
#define GHC_OS_SOLARIS
#elif defined(__svr4__)
#define GHC_OS_SYS5R4
#elif defined(BSD)
#define GHC_OS_BSD
#elif defined(__EMSCRIPTEN__)
#define GHC_OS_WEB
#include <wasi/api.h>
#elif defined(__QNX__)
#define GHC_OS_QNX
#elif defined(__HAIKU__)
#define GHC_OS_HAIKU
#else
#error "Operating system currently not supported!"
#endif
#define GHC_OS_DETECTED
#if (defined(_MSVC_LANG) && _MSVC_LANG >= 201703L)
#if _MSVC_LANG == 201703L
#define GHC_FILESYSTEM_RUNNING_CPP17
#else
#define GHC_FILESYSTEM_RUNNING_CPP20
#endif
#elif (defined(__cplusplus) && __cplusplus >= 201703L)
#if __cplusplus == 201703L
#define GHC_FILESYSTEM_RUNNING_CPP17
#else
#define GHC_FILESYSTEM_RUNNING_CPP20
#endif
#endif
#endif

#if defined(GHC_FILESYSTEM_IMPLEMENTATION)
#define GHC_EXPAND_IMPL
#define GHC_INLINE
#ifdef GHC_OS_WINDOWS
#ifndef GHC_FS_API
#define GHC_FS_API
#endif
#ifndef GHC_FS_API_CLASS
#define GHC_FS_API_CLASS
#endif
#else
#ifndef GHC_FS_API
#define GHC_FS_API __attribute__((visibility("default")))
#endif
#ifndef GHC_FS_API_CLASS
#define GHC_FS_API_CLASS __attribute__((visibility("default")))
#endif
#endif
#elif defined(GHC_FILESYSTEM_FWD)
#define GHC_INLINE
#ifdef GHC_OS_WINDOWS
#ifndef GHC_FS_API
#define GHC_FS_API extern
#endif
#ifndef GHC_FS_API_CLASS
#define GHC_FS_API_CLASS
#endif
#else
#ifndef GHC_FS_API
#define GHC_FS_API extern
#endif
#ifndef GHC_FS_API_CLASS
#define GHC_FS_API_CLASS
#endif
#endif
#else
#define GHC_EXPAND_IMPL
#define GHC_INLINE inline
#ifndef GHC_FS_API
#define GHC_FS_API
#endif
#ifndef GHC_FS_API_CLASS
#define GHC_FS_API_CLASS
#endif
#endif

#ifdef GHC_EXPAND_IMPL

#ifdef GHC_OS_WINDOWS
#include <windows.h>
// additional includes
#include <shellapi.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <wchar.h>
#include <winioctl.h>
#else
#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <sys/param.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>
#ifdef GHC_OS_ANDROID
#include <android/api-level.h>
#if __ANDROID_API__ < 12
#include <sys/syscall.h>
#endif
#include <sys/vfs.h>
#define statvfs statfs
#else
#include <sys/statvfs.h>
#endif
#ifdef GHC_OS_CYGWIN
#include <strings.h>
#endif
#if !defined(__ANDROID__) || __ANDROID_API__ >= 26
#include <langinfo.h>
#endif
#endif
#ifdef GHC_OS_APPLE
#include <Availability.h>
#endif

#if defined(__cpp_impl_three_way_comparison) && defined(__has_include)
#if __has_include(<compare>)
#define GHC_HAS_THREEWAY_COMP
#include <compare>
#endif
#endif

#include <algorithm>
#include <cctype>
#include <chrono>
#include <clocale>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <functional>
#include <memory>
#include <stack>
#include <stdexcept>
#include <string>
#include <system_error>
#include <type_traits>
#include <utility>
#include <vector>

#else  // GHC_EXPAND_IMPL

#if defined(__cpp_impl_three_way_comparison) && defined(__has_include)
#if __has_include(<compare>)
#define GHC_HAS_THREEWAY_COMP
#include <compare>
#endif
#endif
#include <chrono>
#include <fstream>
#include <memory>
#include <stack>
#include <stdexcept>
#include <string>
#include <system_error>
#ifdef GHC_OS_WINDOWS
#include <vector>
#endif
#endif  // GHC_EXPAND_IMPL

// After standard library includes.
// Standard library support for std::string_view.
#if defined(__cpp_lib_string_view)
#define GHC_HAS_STD_STRING_VIEW
#elif defined(_LIBCPP_VERSION) && (_LIBCPP_VERSION >= 4000) && (__cplusplus >= 201402)
#define GHC_HAS_STD_STRING_VIEW
#elif defined(_GLIBCXX_RELEASE) && (_GLIBCXX_RELEASE >= 7) && (__cplusplus >= 201703)
#define GHC_HAS_STD_STRING_VIEW
#elif defined(_MSC_VER) && (_MSC_VER >= 1910 && _MSVC_LANG >= 201703)
#define GHC_HAS_STD_STRING_VIEW
#endif

// Standard library support for std::experimental::string_view.
#if defined(_LIBCPP_VERSION) && (_LIBCPP_VERSION >= 3700 && _LIBCPP_VERSION < 7000) && (__cplusplus >= 201402)
#define GHC_HAS_STD_EXPERIMENTAL_STRING_VIEW
#elif defined(__GNUC__) && (((__GNUC__ == 4) && (__GNUC_MINOR__ >= 9)) || (__GNUC__ > 4)) && (__cplusplus >= 201402)
#define GHC_HAS_STD_EXPERIMENTAL_STRING_VIEW
#elif defined(__GLIBCXX__) && defined(_GLIBCXX_USE_DUAL_ABI) && (__cplusplus >= 201402)
// macro _GLIBCXX_USE_DUAL_ABI is always defined in libstdc++ from gcc-5 and newer
#define GHC_HAS_STD_EXPERIMENTAL_STRING_VIEW
#endif

#if defined(GHC_HAS_STD_STRING_VIEW)
#include <string_view>
#elif defined(GHC_HAS_STD_EXPERIMENTAL_STRING_VIEW)
#include <experimental/string_view>
#endif

#if !defined(GHC_OS_WINDOWS) && !defined(PATH_MAX)
#define PATH_MAX 4096
#endif

//- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
// Behaviour Switches (see README.md, should match the config in test/filesystem_test.cpp):
//- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
// Enforce C++17 API where possible when compiling for C++20, handles the following cases:
// * fs::path::u8string() returns std::string instead of std::u8string
// #define GHC_FILESYSTEM_ENFORCE_CPP17_API
//- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
// LWG #2682 disables the since then invalid use of the copy option create_symlinks on directories
// configure LWG conformance ()
#define LWG_2682_BEHAVIOUR
//- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
// LWG #2395 makes crate_directory/create_directories not emit an error if there is a regular
// file with that name, it is superseded by P1164R1, so only activate if really needed
// #define LWG_2935_BEHAVIOUR
//- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
// LWG #2936 enables new element wise (more expensive) path comparison
// * if this->root_name().native().compare(p.root_name().native()) != 0 return result
// * if this->has_root_directory() and !p.has_root_directory() return -1
// * if !this->has_root_directory() and p.has_root_directory() return -1
// * else result of element wise comparison of path iteration where first comparison is != 0 or 0
//   if all comparisons are 0 (on Windows this implementation does case-insensitive root_name()
//   comparison)
#define LWG_2936_BEHAVIOUR
//- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
// LWG #2937 enforces that fs::equivalent emits an error, if !fs::exists(p1)||!exists(p2)
#define LWG_2937_BEHAVIOUR
//- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
// UTF8-Everywhere is the original behaviour of ghc::filesystem. But since v1.5 the Windows
// version defaults to std::wstring storage backend. Still all std::string will be interpreted
// as UTF-8 encoded. With this define you can enforce the old behavior on Windows, using
// std::string as backend and for fs::path::native() and char for fs::path::c_str(). This
// needs more conversions, so it is (and was before v1.5) slower, bot might help keeping source
// homogeneous in a multi-platform project.
// #define GHC_WIN_DISABLE_WSTRING_STORAGE_TYPE
//- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
// Raise errors/exceptions when invalid unicode codepoints or UTF-8 sequences are found,
// instead of replacing them with the unicode replacement character (U+FFFD).
// #define GHC_RAISE_UNICODE_ERRORS
//- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
// Automatic prefix windows path with "\\?\" if they would break the MAX_PATH length.
// instead of replacing them with the unicode replacement character (U+FFFD).
#ifndef GHC_WIN_DISABLE_AUTO_PREFIXES
#define GHC_WIN_AUTO_PREFIX_LONG_PATH
#endif  // GHC_WIN_DISABLE_AUTO_PREFIXES
//- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

// ghc::filesystem version in decimal (major * 10000 + minor * 100 + patch)
#define GHC_FILESYSTEM_VERSION 10515L

#if !defined(GHC_WITH_EXCEPTIONS) && (defined(__EXCEPTIONS) || defined(__cpp_exceptions) || defined(_CPPUNWIND))
#define GHC_WITH_EXCEPTIONS
#endif
#if !defined(GHC_WITH_EXCEPTIONS) && defined(GHC_RAISE_UNICODE_ERRORS)
#error "Can't raise unicode errors with exception support disabled"
#endif

namespace ghc {
namespace filesystem {

#if defined(GHC_HAS_CUSTOM_STRING_VIEW)
#define GHC_WITH_STRING_VIEW
#elif defined(GHC_HAS_STD_STRING_VIEW)
#define GHC_WITH_STRING_VIEW
using std::basic_string_view;
#elif defined(GHC_HAS_STD_EXPERIMENTAL_STRING_VIEW)
#define GHC_WITH_STRING_VIEW
using std::experimental::basic_string_view;
#endif

// temporary existing exception type for yet unimplemented parts
class GHC_FS_API_CLASS not_implemented_exception : public std::logic_error
{
public:
    not_implemented_exception()
        : std::logic_error("function not implemented yet.")
    {
    }
};

template <typename char_type>
class path_helper_base
{
public:
    using value_type = char_type;
#ifdef GHC_OS_WINDOWS
    static constexpr value_type preferred_separator = '\\';
#else
    static constexpr value_type preferred_separator = '/';
#endif
};

#if __cplusplus < 201703L
template <typename char_type>
constexpr char_type path_helper_base<char_type>::preferred_separator;
#endif

#ifdef GHC_OS_WINDOWS
class path;
namespace detail {
bool has_executable_extension(const path& p);
}
#endif

// [fs.class.path] class path
class GHC_FS_API_CLASS path
#if defined(GHC_OS_WINDOWS) && !defined(GHC_WIN_DISABLE_WSTRING_STORAGE_TYPE)
#define GHC_USE_WCHAR_T
#define GHC_NATIVEWP(p) p.c_str()
#define GHC_PLATFORM_LITERAL(str) L##str
    : private path_helper_base<std::wstring::value_type>
{
public:
    using path_helper_base<std::wstring::value_type>::value_type;
#else
#define GHC_NATIVEWP(p) p.wstring().c_str()
#define GHC_PLATFORM_LITERAL(str) str
    : private path_helper_base<std::string::value_type>
{
public:
    using path_helper_base<std::string::value_type>::value_type;
#endif
    using string_type = std::basic_string<value_type>;
    using path_helper_base<value_type>::preferred_separator;

    // [fs.enum.path.format] enumeration format
    /// The path format in which the constructor argument is given.
    enum format {
        generic_format,  ///< The generic format, internally used by
                         ///< ghc::filesystem::path with slashes
        native_format,   ///< The format native to the current platform this code
                         ///< is build for
        auto_format,     ///< Try to auto-detect the format, fallback to native
    };

    template <class T>
    struct _is_basic_string : std::false_type
    {
    };
    template <class CharT, class Traits, class Alloc>
    struct _is_basic_string<std::basic_string<CharT, Traits, Alloc>> : std::true_type
    {
    };
    template <class CharT>
    struct _is_basic_string<std::basic_string<CharT, std::char_traits<CharT>, std::allocator<CharT>>> : std::true_type
    {
    };
#ifdef GHC_WITH_STRING_VIEW
    template <class CharT, class Traits>
    struct _is_basic_string<basic_string_view<CharT, Traits>> : std::true_type
    {
    };
    template <class CharT>
    struct _is_basic_string<basic_string_view<CharT, std::char_traits<CharT>>> : std::true_type
    {
    };
#endif

    template <typename T1, typename T2 = void>
    using path_type = typename std::enable_if<!std::is_same<path, T1>::value, path>::type;
    template <typename T>
#if defined(__cpp_lib_char8_t) && !defined(GHC_FILESYSTEM_ENFORCE_CPP17_API)
    using path_from_string =
        typename std::enable_if<_is_basic_string<T>::value || std::is_same<char const*, typename std::decay<T>::type>::value || std::is_same<char*, typename std::decay<T>::type>::value || std::is_same<char8_t const*, typename std::decay<T>::type>::value ||
                                    std::is_same<char8_t*, typename std::decay<T>::type>::value || std::is_same<char16_t const*, typename std::decay<T>::type>::value || std::is_same<char16_t*, typename std::decay<T>::type>::value ||
                                    std::is_same<char32_t const*, typename std::decay<T>::type>::value || std::is_same<char32_t*, typename std::decay<T>::type>::value || std::is_same<wchar_t const*, typename std::decay<T>::type>::value ||
                                    std::is_same<wchar_t*, typename std::decay<T>::type>::value,
                                path>::type;
    template <typename T>
    using path_type_EcharT = typename std::enable_if<std::is_same<T, char>::value || std::is_same<T, char8_t>::value || std::is_same<T, char16_t>::value || std::is_same<T, char32_t>::value || std::is_same<T, wchar_t>::value, path>::type;
#else
    using path_from_string =
        typename std::enable_if<_is_basic_string<T>::value || std::is_same<char const*, typename std::decay<T>::type>::value || std::is_same<char*, typename std::decay<T>::type>::value ||
                                    std::is_same<char16_t const*, typename std::decay<T>::type>::value || std::is_same<char16_t*, typename std::decay<T>::type>::value || std::is_same<char32_t const*, typename std::decay<T>::type>::value ||
                                    std::is_same<char32_t*, typename std::decay<T>::type>::value || std::is_same<wchar_t const*, typename std::decay<T>::type>::value || std::is_same<wchar_t*, typename std::decay<T>::type>::value,
                                path>::type;
    template <typename T>
    using path_type_EcharT = typename std::enable_if<std::is_same<T, char>::value || std::is_same<T, char16_t>::value || std::is_same<T, char32_t>::value || std::is_same<T, wchar_t>::value, path>::type;
#endif
    // [fs.path.construct] constructors and destructor
    path() noexcept;
    path(const path& p);
    path(path&& p) noexcept;
    path(string_type&& source, format fmt = auto_format);
    template <class Source, typename = path_from_string<Source>>
    path(const Source& source, format fmt = auto_format);
    template <class InputIterator>
    path(InputIterator first, InputIterator last, format fmt = auto_format);
#ifdef GHC_WITH_EXCEPTIONS
    template <class Source, typename = path_from_string<Source>>
    path(const Source& source, const std::locale& loc, format fmt = auto_format);
    template <class InputIterator>
    path(InputIterator first, InputIterator last, const std::locale& loc, format fmt = auto_format);
#endif
    ~path();

    // [fs.path.assign] assignments
    path& operator=(const path& p);
    path& operator=(path&& p) noexcept;
    path& operator=(string_type&& source);
    path& assign(string_type&& source);
    template <class Source>
    path& operator=(const Source& source);
    template <class Source>
    path& assign(const Source& source);
    template <class InputIterator>
    path& assign(InputIterator first, InputIterator last);

    // [fs.path.append] appends
    path& operator/=(const path& p);
    template <class Source>
    path& operator/=(const Source& source);
    template <class Source>
    path& append(const Source& source);
    template <class InputIterator>
    path& append(InputIterator first, InputIterator last);

    // [fs.path.concat] concatenation
    path& operator+=(const path& x);
    path& operator+=(const string_type& x);
#ifdef GHC_WITH_STRING_VIEW
    path& operator+=(basic_string_view<value_type> x);
#endif
    path& operator+=(const value_type* x);
    path& operator+=(value_type x);
    template <class Source>
    path_from_string<Source>& operator+=(const Source& x);
    template <class EcharT>
    path_type_EcharT<EcharT>& operator+=(EcharT x);
    template <class Source>
    path& concat(const Source& x);
    template <class InputIterator>
    path& concat(InputIterator first, InputIterator last);

    // [fs.path.modifiers] modifiers
    void clear() noexcept;
    path& make_preferred();
    path& remove_filename();
    path& replace_filename(const path& replacement);
    path& replace_extension(const path& replacement = path());
    void swap(path& rhs) noexcept;

    // [fs.path.native.obs] native format observers
    const string_type& native() const noexcept;
    const value_type* c_str() const noexcept;
    operator string_type() const;
    template <class EcharT, class traits = std::char_traits<EcharT>, class Allocator = std::allocator<EcharT>>
    std::basic_string<EcharT, traits, Allocator> string(const Allocator& a = Allocator()) const;
    std::string string() const;
    std::wstring wstring() const;
#if defined(__cpp_lib_char8_t) && !defined(GHC_FILESYSTEM_ENFORCE_CPP17_API)
    std::u8string u8string() const;
#else
    std::string u8string() const;
#endif
    std::u16string u16string() const;
    std::u32string u32string() const;

    // [fs.path.generic.obs] generic format observers
    template <class EcharT, class traits = std::char_traits<EcharT>, class Allocator = std::allocator<EcharT>>
    std::basic_string<EcharT, traits, Allocator> generic_string(const Allocator& a = Allocator()) const;
    std::string generic_string() const;
    std::wstring generic_wstring() const;
#if defined(__cpp_lib_char8_t) && !defined(GHC_FILESYSTEM_ENFORCE_CPP17_API)
    std::u8string generic_u8string() const;
#else
    std::string generic_u8string() const;
#endif
    std::u16string generic_u16string() const;
    std::u32string generic_u32string() const;

    // [fs.path.compare] compare
    int compare(const path& p) const noexcept;
    int compare(const string_type& s) const;
#ifdef GHC_WITH_STRING_VIEW
    int compare(basic_string_view<value_type> s) const;
#endif
    int compare(const value_type* s) const;

    // [fs.path.decompose] decomposition
    path root_name() const;
    path root_directory() const;
    path root_path() const;
    path relative_path() const;
    path parent_path() const;
    path filename() const;
    path stem() const;
    path extension() const;

    // [fs.path.query] query
    bool empty() const noexcept;
    bool has_root_name() const;
    bool has_root_directory() const;
    bool has_root_path() const;
    bool has_relative_path() const;
    bool has_parent_path() const;
    bool has_filename() const;
    bool has_stem() const;
    bool has_extension() const;
    bool is_absolute() const;
    bool is_relative() const;

    // [fs.path.gen] generation
    path lexically_normal() const;
    path lexically_relative(const path& base) const;
    path lexically_proximate(const path& base) const;

    // [fs.path.itr] iterators
    class iterator;
    using const_iterator = iterator;
    iterator begin() const;
    iterator end() const;

private:
    using impl_value_type = value_type;
    using impl_string_type = std::basic_string<impl_value_type>;
    friend class directory_iterator;
    void append_name(const value_type* name);
    static constexpr impl_value_type generic_separator = '/';
    template <typename InputIterator>
    class input_iterator_range
    {
    public:
        typedef InputIterator iterator;
        typedef InputIterator const_iterator;
        typedef typename InputIterator::difference_type difference_type;

        input_iterator_range(const InputIterator& first, const InputIterator& last)
            : _first(first)
            , _last(last)
        {
        }

        InputIterator begin() const { return _first; }
        InputIterator end() const { return _last; }

    private:
        InputIterator _first;
        InputIterator _last;
    };
    friend void swap(path& lhs, path& rhs) noexcept;
    friend size_t hash_value(const path& p) noexcept;
    friend path canonical(const path& p, std::error_code& ec);
    friend bool create_directories(const path& p, std::error_code& ec) noexcept;
    string_type::size_type root_name_length() const noexcept;
    void postprocess_path_with_format(format fmt);
    void check_long_path();
    impl_string_type _path;
#ifdef GHC_OS_WINDOWS
    void handle_prefixes();
    friend bool detail::has_executable_extension(const path& p);
#ifdef GHC_WIN_AUTO_PREFIX_LONG_PATH
    string_type::size_type _prefixLength{0};
#else   // GHC_WIN_AUTO_PREFIX_LONG_PATH
    static const string_type::size_type _prefixLength{0};
#endif  // GHC_WIN_AUTO_PREFIX_LONG_PATH
#else
    static const string_type::size_type _prefixLength{0};
#endif
};

// [fs.path.nonmember] path non-member functions
GHC_FS_API void swap(path& lhs, path& rhs) noexcept;
GHC_FS_API size_t hash_value(const path& p) noexcept;
#ifdef GHC_HAS_THREEWAY_COMP
GHC_FS_API std::strong_ordering operator<=>(const path& lhs, const path& rhs) noexcept;
#endif
GHC_FS_API bool operator==(const path& lhs, const path& rhs) noexcept;
GHC_FS_API bool operator!=(const path& lhs, const path& rhs) noexcept;
GHC_FS_API bool operator<(const path& lhs, const path& rhs) noexcept;
GHC_FS_API bool operator<=(const path& lhs, const path& rhs) noexcept;
GHC_FS_API bool operator>(const path& lhs, const path& rhs) noexcept;
GHC_FS_API bool operator>=(const path& lhs, const path& rhs) noexcept;
GHC_FS_API path operator/(const path& lhs, const path& rhs);

// [fs.path.io] path inserter and extractor
template <class charT, class traits>
std::basic_ostream<charT, traits>& operator<<(std::basic_ostream<charT, traits>& os, const path& p);
template <class charT, class traits>
std::basic_istream<charT, traits>& operator>>(std::basic_istream<charT, traits>& is, path& p);

// [pfs.path.factory] path factory functions
template <class Source, typename = path::path_from_string<Source>>
#if defined(__cpp_lib_char8_t) && !defined(GHC_FILESYSTEM_ENFORCE_CPP17_API)
[[deprecated("use ghc::filesystem::path::path() with std::u8string instead")]]
#endif
path u8path(const Source& source);
template <class InputIterator>
#if defined(__cpp_lib_char8_t) && !defined(GHC_FILESYSTEM_ENFORCE_CPP17_API)
[[deprecated("use ghc::filesystem::path::path() with std::u8string instead")]]
#endif
path u8path(InputIterator first, InputIterator last);

// [fs.class.filesystem_error] class filesystem_error
class GHC_FS_API_CLASS filesystem_error : public std::system_error
{
public:
    filesystem_error(const std::string& what_arg, std::error_code ec);
    filesystem_error(const std::string& what_arg, const path& p1, std::error_code ec);
    filesystem_error(const std::string& what_arg, const path& p1, const path& p2, std::error_code ec);
    const path& path1() const noexcept;
    const path& path2() const noexcept;
    const char* what() const noexcept override;

private:
    std::string _what_arg;
    std::error_code _ec;
    path _p1, _p2;
};

class GHC_FS_API_CLASS path::iterator
{
public:
    using value_type = const path;
    using difference_type = std::ptrdiff_t;
    using pointer = const path*;
    using reference = const path&;
    using iterator_category = std::bidirectional_iterator_tag;

    iterator();
    iterator(const path& p, const impl_string_type::const_iterator& pos);
    iterator& operator++();
    iterator operator++(int);
    iterator& operator--();
    iterator operator--(int);
    bool operator==(const iterator& other) const;
    bool operator!=(const iterator& other) const;
    reference operator*() const;
    pointer operator->() const;

private:
    friend class path;
    impl_string_type::const_iterator increment(const impl_string_type::const_iterator& pos) const;
    impl_string_type::const_iterator decrement(const impl_string_type::const_iterator& pos) const;
    void updateCurrent();
    impl_string_type::const_iterator _first;
    impl_string_type::const_iterator _last;
    impl_string_type::const_iterator _prefix;
    impl_string_type::const_iterator _root;
    impl_string_type::const_iterator _iter;
    path _current;
};

struct space_info
{
    uintmax_t capacity;
    uintmax_t free;
    uintmax_t available;
};

// [fs.enum] enumerations
// [fs.enum.file_type]
enum class file_type {
    none,
    not_found,
    regular,
    directory,
    symlink,
    block,
    character,
    fifo,
    socket,
    unknown,
};

// [fs.enum.perms]
enum class perms : uint16_t {
    none = 0,

    owner_read = 0400,
    owner_write = 0200,
    owner_exec = 0100,
    owner_all = 0700,

    group_read = 040,
    group_write = 020,
    group_exec = 010,
    group_all = 070,

    others_read = 04,
    others_write = 02,
    others_exec = 01,
    others_all = 07,

    all = 0777,
    set_uid = 04000,
    set_gid = 02000,
    sticky_bit = 01000,

    mask = 07777,
    unknown = 0xffff
};

// [fs.enum.perm.opts]
enum class perm_options : uint16_t {
    replace = 3,
    add = 1,
    remove = 2,
    nofollow = 4,
};

// [fs.enum.copy.opts]
enum class copy_options : uint16_t {
    none = 0,

    skip_existing = 1,
    overwrite_existing = 2,
    update_existing = 4,

    recursive = 8,

    copy_symlinks = 0x10,
    skip_symlinks = 0x20,

    directories_only = 0x40,
    create_symlinks = 0x80,
#ifndef GHC_OS_WEB
    create_hard_links = 0x100
#endif
};

// [fs.enum.dir.opts]
enum class directory_options : uint16_t {
    none = 0,
    follow_directory_symlink = 1,
    skip_permission_denied = 2,
};

// [fs.class.file_status] class file_status
class GHC_FS_API_CLASS file_status
{
public:
    // [fs.file_status.cons] constructors and destructor
    file_status() noexcept;
    explicit file_status(file_type ft, perms prms = perms::unknown) noexcept;
    file_status(const file_status&) noexcept;
    file_status(file_status&&) noexcept;
    ~file_status();
    // assignments:
    file_status& operator=(const file_status&) noexcept;
    file_status& operator=(file_status&&) noexcept;
    // [fs.file_status.mods] modifiers
    void type(file_type ft) noexcept;
    void permissions(perms prms) noexcept;
    // [fs.file_status.obs] observers
    file_type type() const noexcept;
    perms permissions() const noexcept;
    friend bool operator==(const file_status& lhs, const file_status& rhs) noexcept { return lhs.type() == rhs.type() && lhs.permissions() == rhs.permissions(); }

private:
    file_type _type;
    perms _perms;
};

using file_time_type = std::chrono::time_point<std::chrono::system_clock>;

// [fs.class.directory_entry] Class directory_entry
class GHC_FS_API_CLASS directory_entry
{
public:
    // [fs.dir.entry.cons] constructors and destructor
    directory_entry() noexcept = default;
    directory_entry(const directory_entry&) = default;
    directory_entry(directory_entry&&) noexcept = default;
#ifdef GHC_WITH_EXCEPTIONS
    explicit directory_entry(const path& p);
#endif
    directory_entry(const path& p, std::error_code& ec);
    ~directory_entry();

    // assignments:
    directory_entry& operator=(const directory_entry&) = default;
    directory_entry& operator=(directory_entry&&) noexcept = default;

    // [fs.dir.entry.mods] modifiers
#ifdef GHC_WITH_EXCEPTIONS
    void assign(const path& p);
    void replace_filename(const path& p);
    void refresh();
#endif
    void assign(const path& p, std::error_code& ec);
    void replace_filename(const path& p, std::error_code& ec);
    void refresh(std::error_code& ec) noexcept;

    // [fs.dir.entry.obs] observers
    const filesystem::path& path() const noexcept;
    operator const filesystem::path&() const noexcept;
#ifdef GHC_WITH_EXCEPTIONS
    bool exists() const;
    bool is_block_file() const;
    bool is_character_file() const;
    bool is_directory() const;
    bool is_fifo() const;
    bool is_other() const;
    bool is_regular_file() const;
    bool is_socket() const;
    bool is_symlink() const;
    uintmax_t file_size() const;
    file_time_type last_write_time() const;
    file_status status() const;
    file_status symlink_status() const;
#endif
    bool exists(std::error_code& ec) const noexcept;
    bool is_block_file(std::error_code& ec) const noexcept;
    bool is_character_file(std::error_code& ec) const noexcept;
    bool is_directory(std::error_code& ec) const noexcept;
    bool is_fifo(std::error_code& ec) const noexcept;
    bool is_other(std::error_code& ec) const noexcept;
    bool is_regular_file(std::error_code& ec) const noexcept;
    bool is_socket(std::error_code& ec) const noexcept;
    bool is_symlink(std::error_code& ec) const noexcept;
    uintmax_t file_size(std::error_code& ec) const noexcept;
    file_time_type last_write_time(std::error_code& ec) const noexcept;
    file_status status(std::error_code& ec) const noexcept;
    file_status symlink_status(std::error_code& ec) const noexcept;

#ifndef GHC_OS_WEB
#ifdef GHC_WITH_EXCEPTIONS
    uintmax_t hard_link_count() const;
#endif
    uintmax_t hard_link_count(std::error_code& ec) const noexcept;
#endif

#ifdef GHC_HAS_THREEWAY_COMP
    std::strong_ordering operator<=>(const directory_entry& rhs) const noexcept;
#endif
    bool operator<(const directory_entry& rhs) const noexcept;
    bool operator==(const directory_entry& rhs) const noexcept;
    bool operator!=(const directory_entry& rhs) const noexcept;
    bool operator<=(const directory_entry& rhs) const noexcept;
    bool operator>(const directory_entry& rhs) const noexcept;
    bool operator>=(const directory_entry& rhs) const noexcept;

private:
    friend class directory_iterator;
#ifdef GHC_WITH_EXCEPTIONS
    file_type status_file_type() const;
#endif
    file_type status_file_type(std::error_code& ec) const noexcept;
    filesystem::path _path;
    file_status _status;
    file_status _symlink_status;
    uintmax_t _file_size = static_cast<uintmax_t>(-1);
#ifndef GHC_OS_WINDOWS
    uintmax_t _hard_link_count = static_cast<uintmax_t>(-1);
#endif
    time_t _last_write_time = 0;
};

// [fs.class.directory.iterator] Class directory_iterator
class GHC_FS_API_CLASS directory_iterator
{
public:
    class GHC_FS_API_CLASS proxy
    {
    public:
        const directory_entry& operator*() const& noexcept { return _dir_entry; }
        directory_entry operator*() && noexcept { return std::move(_dir_entry); }

    private:
        explicit proxy(const directory_entry& dir_entry)
            : _dir_entry(dir_entry)
        {
        }
        friend class directory_iterator;
        friend class recursive_directory_iterator;
        directory_entry _dir_entry;
    };
    using iterator_category = std::input_iterator_tag;
    using value_type = directory_entry;
    using difference_type = std::ptrdiff_t;
    using pointer = const directory_entry*;
    using reference = const directory_entry&;

    // [fs.dir.itr.members] member functions
    directory_iterator() noexcept;
#ifdef GHC_WITH_EXCEPTIONS
    explicit directory_iterator(const path& p);
    directory_iterator(const path& p, directory_options options);
#endif
    directory_iterator(const path& p, std::error_code& ec) noexcept;
    directory_iterator(const path& p, directory_options options, std::error_code& ec) noexcept;
    di


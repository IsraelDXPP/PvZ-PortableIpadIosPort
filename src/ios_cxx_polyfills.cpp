#if defined(__APPLE__) && defined(__arm__)
#include <stdio.h>
#include <wchar.h>
#include <sys/types.h>

#include <istream>
#include <ostream>
#include <fstream>
#include <string>

// Xcode 15 C++ headers assume these are in libc++.dylib, but iOS 9/10 libc++.dylib doesn't have them.
// By explicitly instantiating them here, we force the compiler to generate the code in our binary.

_LIBCPP_BEGIN_NAMESPACE_STD


template streamsize basic_streambuf<char, char_traits<char>>::xsgetn(char_type*, streamsize);
template streamsize basic_streambuf<char, char_traits<char>>::xsputn(const char_type*, streamsize);

template class basic_istream<char, char_traits<char>>;
template class basic_ostream<char, char_traits<char>>;
template class basic_ifstream<char, char_traits<char>>;
template class basic_ofstream<char, char_traits<char>>;
_LIBCPP_END_NAMESPACE_STD

namespace std {
  class _LIBCPP_EXCEPTION_ABI bad_variant_access : public exception {
  public:
    bad_variant_access() noexcept = default;
    virtual ~bad_variant_access() noexcept;
    virtual const char* what() const noexcept;
  };

  bad_variant_access::~bad_variant_access() noexcept {}

  const char* bad_variant_access::what() const noexcept {
    return "bad_variant_access";
  }

  _LIBCPP_NORETURN void __throw_bad_variant_access() {
#ifndef _LIBCPP_NO_EXCEPTIONS
    throw bad_variant_access();
#else
    printf("bad_variant_access thrown\n");
    abort();
#endif
  }
}
#endif

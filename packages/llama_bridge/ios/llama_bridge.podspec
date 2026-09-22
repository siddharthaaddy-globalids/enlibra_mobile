Pod::Spec.new do |s|
  s.name             = 'llama_bridge'
  s.version          = '0.1.0'
  s.summary          = 'FFI bridge to llama.cpp.'
  s.description      = 'Narrow C ABI over llama.cpp for on-device inference.'
  s.homepage         = 'https://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Enlibra' => 'dev@example.com' }
  s.source           = { :path => '.' }

  # Only our bridge is compiled here. llama.cpp itself arrives as a
  # prebuilt xcframework, because CocoaPods cannot drive llama.cpp's CMake
  # build and globbing its sources into a podspec breaks on every upstream
  # file reorganisation.
  #
  # Build it once with:
  #   packages/llama_bridge/tool/build_apple_frameworks.sh
  s.source_files     = '../src/llama_bridge.cpp', '../src/llama_bridge.h'
  s.public_header_files = '../src/llama_bridge.h'
  s.vendored_frameworks = 'Frameworks/llama.xcframework'

  s.dependency 'Flutter'
  s.platform = :ios, '14.0'
  s.libraries = 'c++'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'GCC_PREPROCESSOR_DEFINITIONS' => 'DART_SHARED_LIB=1',
    # Dart looks up symbols by name in the process image, so the linker
    # must not strip LB_EXPORT functions for being unreferenced by Swift.
    'DEAD_CODE_STRIPPING' => 'NO',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
end

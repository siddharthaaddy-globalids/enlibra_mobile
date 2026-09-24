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
  s.source_files     = 'Classes/**/*'
  s.public_header_files = 'Classes/llama_bridge.h'
  s.vendored_frameworks = 'Frameworks/llama.xcframework'

  s.dependency 'Flutter'
  # Matches IOS_MIN_OS_VERSION in llama.cpp's build-xcframework.sh.
  s.platform = :ios, '16.4'
  s.libraries = 'c++'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'GCC_PREPROCESSOR_DEFINITIONS' => 'DART_SHARED_LIB=1',
    # Dart looks up symbols by name in the process image, so the linker
    # must not strip LB_EXPORT functions for being unreferenced by Swift.
    'DEAD_CODE_STRIPPING' => 'NO',
    # use_frameworks! builds this pod as its own dylib, which must link
    # llama.framework itself; CocoaPods does not add it for a vendored
    # xcframework here, leaving every llama_* symbol undefined.
    'OTHER_LDFLAGS' => '$(inherited) -framework llama',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
end

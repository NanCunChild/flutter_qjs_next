#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_qjs_next.podspec' to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_qjs_next'
  s.version          = '0.0.1'
  s.summary          = 'A quickjs engine for flutter.'
  s.description      = <<-DESC
This plugin is a simple js engine for flutter using the `quickjs` project. Plugin currently supports all the platforms except web!
                       DESC
  s.homepage         = 'https://github.com/NanCunChild/flutter_qjs_next'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'NanCunChild' => 'https://github.com/NanCunChild' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*', 'cxx/*.{c,cpp,h}'
  s.public_header_files = 'Classes/**/*.h'
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'
  s.libraries = 'c++'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
  }
  s.user_target_xcconfig = {
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
  s.prepare_command = 'sh ../cxx/prebuild.sh'
  s.swift_version = '5.0'
end

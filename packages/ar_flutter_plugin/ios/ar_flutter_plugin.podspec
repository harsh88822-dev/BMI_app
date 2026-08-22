#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint ar_flutter_plugin.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'ar_flutter_plugin'
  s.version          = '0.6.2'
  s.summary          = 'A Flutter plugin for shared AR experiences.'
  s.description      = <<-DESC
A Flutter plugin for shared AR experiences supporting Android and iOS.
                       DESC
  s.homepage         = 'https://lars.carius.io'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Lars Carius' => 'carius.lars@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.dependency 'GLTFSceneKit'
  s.dependency 'SwiftJWT'
  s.static_framework = true
  #s.dependency 'ARCore/CloudAnchors', '~> 1.12.0'
  #s.dependency 'ARCore', '~> 1.2.0'
  # ARCore 1.32 pins GoogleToolboxForMac 2.x and nanopb 2.x, which cannot be
  # resolved with current ML Kit pods. ARCore 1.51 uses their compatible 4.x
  # and 3.x dependency lines respectively.
  s.dependency 'ARCore/CloudAnchors', '~> 1.51.0'
  s.platform = :ios, '15.5'


  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end

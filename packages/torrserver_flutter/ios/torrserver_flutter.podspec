Pod::Spec.new do |s|
  s.name             = 'torrserver_flutter'
  s.version          = '0.0.8'
  s.summary          = 'TorrServer Flutter iOS plugin'
  s.description      = <<-DESC
A Flutter package embedding TorrServer as an in-process XCFramework for iOS.
                       DESC
  s.homepage         = 'https://github.com/aymanisthedude26-png/torrserver_flutter'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'TorrServer Flutter Contributors' => 'contributors@torrserver.local' }

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'

  s.platform = :ios, '14.0'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'OTHER_LDFLAGS' => '$(inherited) -framework SystemConfiguration'
  }
  s.swift_version = '5.0'

  # VyseTV: CoreFoundation and libresolv are what a Go-built static library usually
  # asks for at link time on top of the three below; both are part of iOS.
  s.frameworks = 'SystemConfiguration', 'Foundation', 'Security', 'CoreFoundation'
  s.libraries = 'resolv'
  s.vendored_frameworks = 'TorrServerKit.xcframework'

  # Download XCFramework hook
  s.prepare_command = <<-CMD
    set -e
    VERSION="0.0.8"
    LOCAL_BIN="${TORRSERVER_FLUTTER_LOCAL_BINARIES}"
    # VyseTV: archives kept inside the package (binaries/) are used before any download
    if [ -z "$LOCAL_BIN" ] && [ -d "../binaries" ]; then
      LOCAL_BIN="../binaries"
    fi

    if [ -n "$LOCAL_BIN" ] && [ -d "$LOCAL_BIN/TorrServerKit.xcframework" ]; then
      echo "Using local TorrServerKit.xcframework from $LOCAL_BIN"
      rm -rf TorrServerKit.xcframework
      cp -R "$LOCAL_BIN/TorrServerKit.xcframework" .
    elif [ -n "$LOCAL_BIN" ] && [ -f "$LOCAL_BIN/TorrServerKit.xcframework.zip" ]; then
      echo "Unzipping local TorrServerKit.xcframework.zip from $LOCAL_BIN"
      rm -rf TorrServerKit.xcframework
      unzip -q "$LOCAL_BIN/TorrServerKit.xcframework.zip" -d .
    elif [ ! -d "TorrServerKit.xcframework" ]; then
      echo "Downloading TorrServerKit.xcframework from GitHub Releases..."
      curl -fsL "https://github.com/aymanisthedude26-png/torrserver_flutter/releases/download/v${VERSION}/checksums.txt" -o checksums.txt || rm -f checksums.txt
      curl -fsL "https://github.com/aymanisthedude26-png/torrserver_flutter/releases/download/v${VERSION}/TorrServerKit.xcframework.zip" -o TorrServerKit.xcframework.zip || rm -f TorrServerKit.xcframework.zip
      if [ -s "TorrServerKit.xcframework.zip" ]; then
        if [ -f "checksums.txt" ]; then
          EXPECTED_HASH=$(grep "TorrServerKit.xcframework.zip" checksums.txt | awk '{print $1}')
          if [ -n "$EXPECTED_HASH" ]; then
            COMPUTED_HASH=$(shasum -a 256 TorrServerKit.xcframework.zip | awk '{print $1}')
            if [ "$EXPECTED_HASH" != "$COMPUTED_HASH" ]; then
              echo "Error: SHA-256 mismatch for TorrServerKit.xcframework.zip (expected $EXPECTED_HASH, got $COMPUTED_HASH)"
              rm -f TorrServerKit.xcframework.zip checksums.txt
              exit 1
            fi
            echo "Verified SHA-256 for TorrServerKit.xcframework.zip: $COMPUTED_HASH"
          fi
          rm -f checksums.txt
        fi

        unzip -q TorrServerKit.xcframework.zip -d . || true
      fi
      rm -f TorrServerKit.xcframework.zip checksums.txt
      if [ ! -d "TorrServerKit.xcframework" ]; then
        echo "TorrServerKit.xcframework is not available: building without the torrent engine."
      fi
    fi
  CMD
end

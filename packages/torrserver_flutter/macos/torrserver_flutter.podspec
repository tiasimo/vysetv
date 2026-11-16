Pod::Spec.new do |s|
  s.name             = 'torrserver_flutter'
  s.version          = '0.0.8'
  s.summary          = 'TorrServer Flutter macOS plugin'
  s.description      = <<-DESC
Flutter package wrapping TorrServer for macOS desktop via subprocess model.
                       DESC
  s.homepage         = 'https://github.com/aymanisthedude26-png/torrserver_flutter'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'TorrServer Flutter Contributors' => 'contributors@torrserver.local' }

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.14'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'

  s.resources = ['bin/torrserver']

  # Download macOS TorrServer binary hook
  s.prepare_command = <<-CMD
    set -e
    VERSION="0.0.8"
    LOCAL_BIN="${TORRSERVER_FLUTTER_LOCAL_BINARIES}"
    # VyseTV: archives kept inside the package (binaries/) are used before any download
    if [ -z "$LOCAL_BIN" ] && [ -d "../binaries" ]; then
      LOCAL_BIN="../binaries"
    fi
    mkdir -p bin

    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
      ARCH_NAME="amd64"
    else
      ARCH_NAME="arm64"
    fi

    ARCHIVE_NAME="torrserver-darwin-${ARCH_NAME}.tar.gz"
    BIN_NAME="torrserver-darwin-${ARCH_NAME}"

    # VyseTV: an empty file is a placeholder left by an earlier run without network; try again
    if [ -f "bin/torrserver" ] && [ ! -s "bin/torrserver" ]; then
      rm -f bin/torrserver
    fi

    if [ -n "$LOCAL_BIN" ] && [ -f "$LOCAL_BIN/torrserver-darwin-arm64.tar.gz" ] && [ -f "$LOCAL_BIN/torrserver-darwin-amd64.tar.gz" ]; then
      # VyseTV: both architectures are in the package, so they are joined into one
      # file that runs on Intel and Apple silicon Macs, whichever machine builds.
      echo "Joining the local macOS archives from $LOCAL_BIN into one universal engine"
      rm -rf bin/ts-local
      mkdir -p bin/ts-local
      tar -xzf "$LOCAL_BIN/torrserver-darwin-arm64.tar.gz" -C bin/ts-local/
      tar -xzf "$LOCAL_BIN/torrserver-darwin-amd64.tar.gz" -C bin/ts-local/
      rm -f bin/torrserver
      lipo -create bin/ts-local/torrserver-darwin-arm64 bin/ts-local/torrserver-darwin-amd64 -output bin/torrserver || cp "bin/ts-local/$BIN_NAME" bin/torrserver
      rm -rf bin/ts-local
      chmod 755 bin/torrserver
      # Apple silicon only runs signed code; an ad-hoc signature is enough
      codesign --force --sign - bin/torrserver || true
    elif [ -n "$LOCAL_BIN" ] && [ -f "$LOCAL_BIN/$ARCHIVE_NAME" ]; then
      echo "Extracting local macOS archive from $LOCAL_BIN/$ARCHIVE_NAME"
      tar -xzf "$LOCAL_BIN/$ARCHIVE_NAME" -C bin/
      if [ -f "bin/$BIN_NAME" ]; then
        mv "bin/$BIN_NAME" bin/torrserver
      fi
      chmod 755 bin/torrserver
    elif [ -n "$LOCAL_BIN" ] && [ -f "$LOCAL_BIN/$BIN_NAME" ]; then
      echo "Using local macOS binary from $LOCAL_BIN"
      cp "$LOCAL_BIN/$BIN_NAME" bin/torrserver
      chmod 755 bin/torrserver
    elif [ ! -f "bin/torrserver" ]; then
      echo "Downloading TorrServer macOS compressed archive ($ARCHIVE_NAME) from GitHub Releases..."
      curl -fsL "https://github.com/aymanisthedude26-png/torrserver_flutter/releases/download/v${VERSION}/checksums.txt" -o "bin/checksums.txt" || rm -f bin/checksums.txt
      curl -fsL "https://github.com/aymanisthedude26-png/torrserver_flutter/releases/download/v${VERSION}/${ARCHIVE_NAME}" -o "bin/${ARCHIVE_NAME}" || rm -f "bin/${ARCHIVE_NAME}"
      if [ -f "bin/${ARCHIVE_NAME}" ] && [ -s "bin/${ARCHIVE_NAME}" ]; then
        if [ -f "bin/checksums.txt" ]; then
          EXPECTED_HASH=$(grep "$ARCHIVE_NAME" bin/checksums.txt | awk '{print $1}')
          if [ -n "$EXPECTED_HASH" ]; then
            COMPUTED_HASH=$(shasum -a 256 "bin/${ARCHIVE_NAME}" | awk '{print $1}')
            if [ "$EXPECTED_HASH" != "$COMPUTED_HASH" ]; then
              echo "Error: SHA-256 checksum mismatch for $ARCHIVE_NAME (expected $EXPECTED_HASH, got $COMPUTED_HASH)"
              rm -f "bin/${ARCHIVE_NAME}" bin/checksums.txt
              exit 1
            fi
            echo "Verified SHA-256 for $ARCHIVE_NAME: $COMPUTED_HASH"
          fi
        fi

        tar -xzf "bin/${ARCHIVE_NAME}" -C bin/ || true
        if [ -f "bin/$BIN_NAME" ]; then
          mv "bin/$BIN_NAME" bin/torrserver || true
        fi
        chmod 755 bin/torrserver || true
      fi
      rm -f "bin/${ARCHIVE_NAME}" bin/checksums.txt

      # Fallback: the official TorrServer builds (YouROK). VyseTV: both
      # architectures go into one file, so the app's engine runs on Intel and
      # Apple silicon Macs whichever machine built it.
      if [ ! -f "bin/torrserver" ] || [ ! -s "bin/torrserver" ]; then
        echo "Fallback: downloading the official TorrServer builds from the upstream YouROK release..."
        for A in arm64 amd64; do
          curl -fsL "https://github.com/YouROK/TorrServer/releases/latest/download/TorrServer-darwin-${A}" -o "bin/ts-${A}" || rm -f "bin/ts-${A}"
        done
        rm -f bin/torrserver
        if [ -s "bin/ts-arm64" ] && [ -s "bin/ts-amd64" ]; then
          lipo -create bin/ts-arm64 bin/ts-amd64 -output bin/torrserver || rm -f bin/torrserver
        fi
        if [ ! -s "bin/torrserver" ] && [ -s "bin/ts-${ARCH_NAME}" ]; then
          cp "bin/ts-${ARCH_NAME}" bin/torrserver
        fi
        rm -f bin/ts-arm64 bin/ts-amd64
        if [ -s "bin/torrserver" ]; then
          chmod 755 bin/torrserver || true
          # Apple silicon only runs signed code; an ad-hoc signature is enough
          codesign --force --sign - bin/torrserver || true
        fi
      fi

      # Guarantee placeholder exists so CocoaPods s.resources does not fail if offline
      if [ ! -f "bin/torrserver" ]; then
        touch bin/torrserver
      fi
    fi
  CMD
end

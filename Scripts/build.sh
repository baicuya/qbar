#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
cd "$task_root"
mkdir -p build
swiftc App/BrandDrawing.swift Scripts/GenerateIcon.swift -o build/qbar-icon-generator
build/qbar-icon-generator "$task_root"
xcodegen generate
xcodebuild -project Qbar.xcodeproj -scheme Qbar -configuration Release -derivedDataPath build build "CODE_SIGN_IDENTITY=${QBAR_SIGNING_IDENTITY:--}"
mkdir -p dist
ditto build/Build/Products/Release/Qbar.app dist/Qbar.app
ditto -c -k --sequesterRsrc --keepParent dist/Qbar.app dist/Qbar.zip
print "Built: $task_root/dist/Qbar.app"

#!/usr/bin/env bash
# Builds AcidFlow.scr with Mono's C# compiler (Linux/macOS). Output targets .NET Framework 4.8 x64.
set -euo pipefail
cd "$(dirname "$0")"
mcs -sdk:4.8 -target:winexe -platform:x64 -optimize+ -nologo -warn:4 \
  -out:AcidFlow.scr \
  -r:System.Windows.Forms.dll -r:System.Drawing.dll \
  -r:lib/Microsoft.Web.WebView2.Core.dll -r:lib/Microsoft.Web.WebView2.WinForms.dll \
  -resource:lib/Microsoft.Web.WebView2.Core.dll,Microsoft.Web.WebView2.Core.dll \
  -resource:lib/Microsoft.Web.WebView2.WinForms.dll,Microsoft.Web.WebView2.WinForms.dll \
  -resource:lib/WebView2Loader.dll,WebView2Loader.dll \
  -resource:lib/AcidFlow.html,AcidFlow.html \
  -resource:lib/settings.json,settings.json \
  AcidFlowSaver.cs
ls -la AcidFlow.scr

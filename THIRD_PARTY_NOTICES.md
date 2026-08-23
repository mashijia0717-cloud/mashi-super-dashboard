# Third-party notices

## Stats

Parts of Apple SMC sensor access are derived from Stats:
https://github.com/exelban/stats

MIT License

Copyright (c) 2019-2026 Serhiy Mytrovtsiy

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Mole reference

Product concepts for bounded storage analysis and maintenance safety were studied from:
https://github.com/tw93/Mole

Mole is licensed under GPL-3.0. CPAQuotaBar does not copy, link, bundle, or execute
Mole source code. Related features in CPAQuotaBar are clean-room implementations
using macOS platform APIs, with separate data models and behavior.

## libimobiledevice toolchain

The application bundles dynamically linked command-line builds of
libimobiledevice, libusbmuxd, libplist, libimobiledevice-glue, and OpenSSL to
read battery information from iPhone and iPad devices that the user has paired
with Finder. The `comptest` helper is compiled from Nikias Bassen's published
companion-device example and is used to query a paired Apple Watch through its
iPhone.

Source projects and notices:

- https://github.com/libimobiledevice/libimobiledevice
- https://github.com/libimobiledevice/libusbmuxd
- https://github.com/libimobiledevice/libplist
- https://github.com/libimobiledevice/libimobiledevice-glue
- https://gist.github.com/nikias/ebc6e975dc908f3741af0f789c5b1088
- https://www.openssl.org/source/license.html

The LGPL license text distributed with the toolchain is included at
`Resources/libimobiledevice/COPYING`. These executables and dynamic libraries
remain replaceable files inside the application resource bundle.

## 9Router reference

The Antigravity OAuth, token refresh, subscription discovery, and model quota
data flow was implemented with reference to:
https://github.com/decolua/9router

MIT License

Copyright (c) 2024-2026 decolua and contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

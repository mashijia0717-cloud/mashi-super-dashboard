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

The existing `Resources/libimobiledevice/COPYING` contains GPL-2.0 text,
not the LGPL text. Packaging preserves that file and adds LGPL-2.1 text at
`Contents/Resources/Licenses/LGPL-2.1.txt` and the OpenSSL 3 Apache-2.0
license at `Contents/Resources/Licenses/OpenSSL-Apache-2.0.txt`. Copies of
these texts are maintained under `Helpers/Licenses/`. The executables and
dynamic libraries remain replaceable files inside the application resource
bundle. The original bundle's `NOTICE.md` is also retained.

The existing binary snapshot does not include exact source revisions or
build recipes for these tools, nor a separate license for the companion
example. The source links above are attribution references, not a claim
that complete corresponding sources accompany this package.

## m1ddc / display helpers

`Helpers/m1ddc-vendor` contains the required transport-discovery source and
headers from the locally supplied, modified m1ddc snapshot:
https://github.com/waydabber/m1ddc

MIT License — Copyright (c) 2021 waydabber.

The complete license is preserved at `Helpers/m1ddc-vendor/LICENSE` and
shipped as `Contents/Resources/Licenses/m1ddc-MIT.txt`. `DDCControl` links
the transport-discovery implementation; the standalone m1ddc executable and
its CLI are not shipped. The snapshot includes local transport changes and
is not identified as an unmodified upstream release. Helper source origins
and the narrowly scoped relocation changes are recorded in `Helpers/README.md`.

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

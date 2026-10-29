# Sample grid files

These are public files that the grid tests read.
They were all downloaded on 2026-10-29.
The tests never use the network.
The files are kept byte for byte as downloaded, except `f0540mag`, which is stored unzipped.

## harmonica test fixtures (BSD-3-Clause)

Source: https://github.com/fatiando/harmonica, folder `test/data/`.
Each file was downloaded from `https://raw.githubusercontent.com/fatiando/harmonica/main/test/data/<file>`.

Files:
- `om_byte.grd`, `om_byte.grd.gi`, `om_byte.grd.xml`
- `om_short.grd`, `om_short.grd.gi`, `om_short.grd.xml`
- `om_long.grd`, `om_long.grd.gi`, `om_long.grd.xml`
- `om_float.grd`, `om_float.grd.gi`, `om_float.grd.xml`
- `om_double.grd`, `om_double.grd.gi`, `om_double.grd.xml`
- `om_order.grd`, `om_order.grd.gi`, `om_order.grd.xml`
- `om_rotate.grd`, `om_rotate.grd.gi`, `om_rotate.grd.xml`
- `om_compress.grd`, `om_compress.grd.gi`, `om_compress.grd.xml`
- `incomplete_grid.grd`

Licence (from https://raw.githubusercontent.com/fatiando/harmonica/main/LICENSE.txt):

```text
Copyright (c) 2018 The Harmonica Developers
All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice,
  this list of conditions and the following disclaimer.
* Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.
* Neither the name of the copyright holder nor the names of its contributors
  may be used to endorse or promote products derived from this software without
  specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Loop3D geosoft_grid test data (MIT)

Source: https://github.com/Loop3D/geosoft_grid, folder `test_data/`.
Each file was downloaded from `https://raw.githubusercontent.com/Loop3D/geosoft_grid/HEAD/test_data/<file>`.
The repository says the data comes from CPRM (the Geological Survey of Brazil).

Files:
- `test_compressed.grd`, `test_compressed.grd.gi`, `test_compressed.grd.xml`
- `test_uncompressed.grd`, `test_uncompressed.grd.gi`, `test_uncompressed.grd.xml`

Licence (from https://raw.githubusercontent.com/Loop3D/geosoft_grid/HEAD/LICENSE):

```text
MIT License

Copyright (c) 2022 Loop3D

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
```

## USGS Data Series 355 (US public domain)

Source: https://pubs.usgs.gov/ds/355/ (readme: https://pubs.usgs.gov/ds/355/data/00README.txt).
Works of the U.S. Geological Survey are in the public domain in the United States.

Files:
- `mag_4126.grd` from https://pubs.usgs.gov/ds/355/data/mag_4126.grd
- `mag_4126.grd.gi` from https://pubs.usgs.gov/ds/355/data/mag_4126.grd.gi

## GDAL autotest data (MIT)

Source: https://github.com/OSGeo/gdal, folder `autotest/gdrivers/data/ers/`.

Files:
- `mag4014.ers` from https://raw.githubusercontent.com/OSGeo/gdal/master/autotest/gdrivers/data/ers/mag4014.ers
- `mag4014` from https://raw.githubusercontent.com/OSGeo/gdal/master/autotest/gdrivers/data/ers/mag4014

Licence (the general GDAL licence, from https://raw.githubusercontent.com/OSGeo/gdal/master/LICENSE.TXT):

```text
GDAL/OGR General
----------------

In general GDAL/OGR is licensed under an MIT style license with the
following terms:

Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files (the "Software"),
to deal in the Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included
in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
```

## USGS Open-File Report 01-0081 (US public domain)

Source: https://pubs.usgs.gov/of/2001/ofr-01-0081/ (Arizona aeromagnetic data).
Works of the U.S. Geological Survey are in the public domain in the United States.

Files:
- `f0540mag.ers` from https://pubs.usgs.gov/of/2001/ofr-01-0081/data/ermapper/f0540mag.ers
- `f0540mag` from https://pubs.usgs.gov/of/2001/ofr-01-0081/data/ermapper/f0540mag.gz, stored unzipped (big-endian `Float32`, null value `1E+20`).

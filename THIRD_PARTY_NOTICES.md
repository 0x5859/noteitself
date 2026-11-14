# Third-party notices

noteitself has no third-party dependencies: it uses only Apple's system
frameworks. One function is adapted from published code.

## Uneven capsule distance function

`sd_uneven_capsule` in `Sources/Render/Shaders.metal`, and its CPU copy `sd` in
`Tools/ShaderCheck/main.swift`, are adapted from the "Uneven Capsule" 2D signed
distance function by Inigo Quilez
(<https://iquilezles.org/articles/distfunctions2d/>,
<https://www.shadertoy.com/view/4lcBWn>), which its author publishes under the
MIT License:

> The MIT License
>
> Copyright © Inigo Quilez
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in
> all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

## System resources used at runtime

- Toolbar icons are SF Symbols, drawn by the system at runtime. No symbol
  artwork is included in this repository; their use is governed by Apple's
  license for SF Symbols.
- PDF rendering, compression (LZFSE) and image coding come from Apple's
  frameworks on the device.

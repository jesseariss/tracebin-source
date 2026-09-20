# Geometry reference fixtures

`binforge.py` is the project's Python reference implementation. Its executable example constructs
a synthetic wrench mask from rectangles and circles, extracts the outer contour, then writes a bin.
The original `wrench_bin.stl` is the reference output used to develop the Swift port.
`swift_wrench_bin.stl` is the corresponding Swift comparison output. These are regression fixtures,
not scans of a person's possessions or production models to redistribute under someone else's name.

`TraceBinTests/BinBuilderTests.swift` embeds the reference pocket coordinates and checks the
approximately 1,360-triangle unnotched result, dimensions, watertightness and notch behavior. The fixtures
use the project's original geometry implementation; upstream Gridfinity notices are retained in
`THIRD-PARTY-NOTICES.md`.

Python is optional. To run the synthetic example independently, create a virtual environment and
install NumPy and OpenCV (`numpy` and `opencv-python`), then run `binforge.py` from a temporary working
directory with an output filename. Do not overwrite the checked-in fixtures during an experiment.
Different dependency versions can change image-contour sampling. The iOS app does not bundle or
require either Python package.

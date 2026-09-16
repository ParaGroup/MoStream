# ===------------------------------------------------------------------------=== #
#  This program is free software; you can redistribute it and/or modify it
#  under the terms of the GNU Lesser General Public License version 3 as
#  published by the Free Software Foundation.
#  
#  This program is distributed in the hope that it will be useful, but WITHOUT
#  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
#  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public
#  License for more details.
#  
#  You should have received a copy of the GNU Lesser General Public License
#  along with this program; if not, write to the Free Software Foundation,
#  Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
# ===------------------------------------------------------------------------=== #

from std.memory import unsafe_memcpy, unsafe_memset
from std.memory.alloc import unsafe_alloc
from std.memory import Pointer

# A simple PPM image class with planar RGB data layout (Struct of Arrays)
struct PPMImage(Copyable & Deinitable):
    var width: Int
    var height: Int
    var data_ptr: Pointer[UInt8, MutUntrackedOrigin]  # W*H*3 bytes, planar

    # constructor I
    def __init__(out self, width: Int, height: Int):
        self.width = width
        self.height = height
        var num_bytes = width * height * 3
        self.data_ptr = unsafe_alloc[UInt8](num_bytes)
        unsafe_memset(self.data_ptr, UInt8(0), num_bytes)

    # constructor II
    def __init__(out self, width: Int, height: Int, fill: UInt8):
        self.width = width
        self.height = height
        var num_bytes = width * height * 3
        self.data_ptr = unsafe_alloc[UInt8](num_bytes)
        unsafe_memset(self.data_ptr, fill, num_bytes)

    # copy constructor
    def __init__(out self, *, copy: Self):
        self.width = copy.width
        self.height = copy.height
        var num_bytes = self.width * self.height * 3
        if num_bytes > 0:
            self.data_ptr = unsafe_alloc[UInt8](num_bytes)
            unsafe_memcpy(dest=self.data_ptr, src=copy.data_ptr, count=num_bytes)
        else:
            self.data_ptr = Pointer[UInt8, MutUntrackedOrigin].unsafe_dangling()

    # move constructor
    def __init__(out self, *, deinit move: Self):
        self.width = move.width
        self.height = move.height
        self.data_ptr = move.data_ptr

    # destructor
    def __deinit__(deinit self):
        self.data_ptr.unsafe_free()

    # get number of bytes in the image data
    @always_inline
    def num_bytes(self) -> Int:
        return self.width * self.height * 3

    # get number of pixels in the image
    @always_inline
    def plane_size(self) -> Int:
        return self.width * self.height

    # get pointer to the RED channel array
    @always_inline
    def r_ptr(self) -> Pointer[UInt8, MutUntrackedOrigin]:
        return self.data_ptr

    # get pointer to the GREEN channel array
    @always_inline
    def g_ptr(self) -> Pointer[UInt8, MutUntrackedOrigin]:
        return self.data_ptr.unsafe_offset(self.width * self.height)

    # get pointer to the BLUE channel array
    @always_inline
    def b_ptr(self) -> Pointer[UInt8, MutUntrackedOrigin]:
        return self.data_ptr.unsafe_offset(2 * self.width * self.height)

    # get pixel RED value at (x, y)
    @always_inline
    def get_r(self, x: Int, y: Int) -> UInt8:
        return self.r_ptr().unsafe_offset(y * self.width + x).unsafe_load()

    # get pixel GREEN value at (x, y)
    @always_inline
    def get_g(self, x: Int, y: Int) -> UInt8:
        return self.g_ptr().unsafe_offset(y * self.width + x).unsafe_load()

    # get pixel BLUE value at (x, y)
    @always_inline
    def get_b(self, x: Int, y: Int) -> UInt8:
        return self.b_ptr().unsafe_offset(y * self.width + x).unsafe_load()

    # set pixel at (x, y) to (r, g, b)
    @always_inline
    def set_pixel(mut self, x: Int, y: Int, r: UInt8, g: UInt8, b: UInt8):
        var idx = y * self.width + x
        self.r_ptr().unsafe_offset(idx).unsafe_store(0, r)
        self.g_ptr().unsafe_offset(idx).unsafe_store(0, g)
        self.b_ptr().unsafe_offset(idx).unsafe_store(0, b)

    # compute a simple checksum by summing all bytes as UInt64
    @always_inline
    def checksum(self) -> UInt64:
        var total: UInt64 = 0
        var n = self.num_bytes()
        for i in range(n):
            total += self.data_ptr.unsafe_offset(i)[].cast[DType.uint64]()
        return total

    # implement Writable interface for debugging purposes
    def write_to[W: Writer](self, mut writer: W):
        writer.write("PPMImage[", self.width, "x", self.height, "] (planar)")

    # create a test gradient image for benchmarking
    @staticmethod
    def create_gradient(width: Int, height: Int) -> PPMImage:
        var img = PPMImage(width, height)
        for y in range(height):
            for x in range(width):
                var r = UInt8((x * 255) // max(width - 1, 1))
                var g = UInt8((y * 255) // max(height - 1, 1))
                var b = UInt8(((x + y) * 127) // max(width + height - 2, 1))
                img.set_pixel(x, y, r, g, b)
        return img^

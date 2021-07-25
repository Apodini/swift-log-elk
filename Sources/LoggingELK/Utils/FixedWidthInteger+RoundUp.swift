//
//  FixedWidthInteger+RoundUp.swift
//
//  Created by Philipp Zagar on 24.07.21.
//

extension FixedWidthInteger {
    /// From: Swift NIO `ByteBuffer-int.swift`(can't be used since internal protection level)
    /// Returns the next power of two.
    @inlinable
    func nextPowerOf2() -> Self {
        guard self != 0 else {
            return 1
        }
        return 1 << (Self.bitWidth - (self - 1).leadingZeroBitCount)
    }
}

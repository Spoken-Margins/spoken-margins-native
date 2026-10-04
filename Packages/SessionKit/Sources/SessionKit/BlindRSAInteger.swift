import Foundation

// A small unsigned big integer for the phone's half of RSA blind signatures
// (PrivacyPassToken.swift). CryptoKit has no RSA, and the phone only ever
// uses a public key, so plain schoolbook arithmetic is enough: its timing
// reveals nothing secret, and a token needs a few dozen multiplications.

struct BlindRSAInteger: Equatable, Comparable, Sendable {
    /// Little-endian 64-bit limbs with no high zero limbs; zero is empty.
    private(set) var limbs: [UInt64]

    init(_ value: UInt64 = 0) {
        limbs = value == 0 ? [] : [value]
    }

    private init(limbs: [UInt64]) {
        self.limbs = limbs
        normalize()
    }

    /// Reads big-endian bytes, as RSA and the RFC test vectors write numbers.
    init(bigEndian bytes: Data) {
        var out = [UInt64](repeating: 0, count: (bytes.count + 7) / 8)
        for (offset, byte) in bytes.reversed().enumerated() {
            out[offset / 8] |= UInt64(byte) << (UInt64(offset % 8) * 8)
        }
        self.init(limbs: out)
    }

    /// Big-endian bytes padded to `length`, or nil if the number needs more.
    func bigEndian(length: Int) -> Data? {
        guard (bitWidth + 7) / 8 <= length else { return nil }
        var out = Data(count: length)
        for index in 0..<length {
            let byteIndex = index
            let limb = byteIndex / 8
            guard limb < limbs.count else { break }
            out[length - 1 - index] = UInt8(truncatingIfNeeded: limbs[limb] >> (UInt64(byteIndex % 8) * 8))
        }
        return out
    }

    var isZero: Bool { limbs.isEmpty }

    var bitWidth: Int {
        guard let top = limbs.last else { return 0 }
        return limbs.count * 64 - top.leadingZeroBitCount
    }

    private mutating func normalize() {
        while limbs.last == 0 { limbs.removeLast() }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.limbs.count != rhs.limbs.count { return lhs.limbs.count < rhs.limbs.count }
        for index in stride(from: lhs.limbs.count - 1, through: 0, by: -1) where lhs.limbs[index] != rhs.limbs[index] {
            return lhs.limbs[index] < rhs.limbs[index]
        }
        return false
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        var out = [UInt64](repeating: 0, count: max(lhs.limbs.count, rhs.limbs.count) + 1)
        var carry: UInt64 = 0
        for index in 0..<(out.count - 1) {
            let a = index < lhs.limbs.count ? lhs.limbs[index] : 0
            let b = index < rhs.limbs.count ? rhs.limbs[index] : 0
            let (sum1, overflow1) = a.addingReportingOverflow(b)
            let (sum2, overflow2) = sum1.addingReportingOverflow(carry)
            out[index] = sum2
            carry = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
        }
        out[out.count - 1] = carry
        return Self(limbs: out)
    }

    /// lhs - rhs; the caller guarantees lhs >= rhs.
    static func - (lhs: Self, rhs: Self) -> Self {
        precondition(!(lhs < rhs), "BlindRSAInteger subtraction underflow")
        var out = lhs.limbs
        var borrow: UInt64 = 0
        for index in 0..<out.count {
            let b = index < rhs.limbs.count ? rhs.limbs[index] : 0
            let (diff1, overflow1) = out[index].subtractingReportingOverflow(b)
            let (diff2, overflow2) = diff1.subtractingReportingOverflow(borrow)
            out[index] = diff2
            borrow = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
        }
        return Self(limbs: out)
    }

    static func * (lhs: Self, rhs: Self) -> Self {
        guard !lhs.isZero, !rhs.isZero else { return Self() }
        var out = [UInt64](repeating: 0, count: lhs.limbs.count + rhs.limbs.count)
        for i in 0..<lhs.limbs.count {
            var carry: UInt64 = 0
            for j in 0..<rhs.limbs.count {
                let (high, low) = lhs.limbs[i].multipliedFullWidth(by: rhs.limbs[j])
                let (sum1, overflow1) = low.addingReportingOverflow(out[i + j])
                let (sum2, overflow2) = sum1.addingReportingOverflow(carry)
                out[i + j] = sum2
                carry = high &+ (overflow1 ? 1 : 0) &+ (overflow2 ? 1 : 0)
            }
            out[i + rhs.limbs.count] = carry
        }
        return Self(limbs: out)
    }

    private func shiftedLeft(by bits: Int) -> Self {
        guard !isZero, bits > 0 else { return self }
        let whole = bits / 64, part = UInt64(bits % 64)
        var out = [UInt64](repeating: 0, count: limbs.count + whole + 1)
        for (index, limb) in limbs.enumerated() {
            out[index + whole] |= limb << part
            if part > 0 { out[index + whole + 1] |= limb >> (64 - part) }
        }
        return Self(limbs: out)
    }

    private mutating func shiftRightOne() {
        for index in 0..<limbs.count {
            limbs[index] >>= 1
            if index + 1 < limbs.count { limbs[index] |= limbs[index + 1] << 63 }
        }
        normalize()
    }

    private mutating func setBit(_ bit: Int) {
        let limb = bit / 64
        if limbs.count <= limb { limbs += [UInt64](repeating: 0, count: limb - limbs.count + 1) }
        limbs[limb] |= 1 << UInt64(bit % 64)
    }

    /// Shift-and-subtract long division. The divisor must not be zero.
    func quotientAndRemainder(dividingBy divisor: Self) -> (quotient: Self, remainder: Self) {
        precondition(!divisor.isZero, "BlindRSAInteger division by zero")
        guard !(self < divisor) else { return (Self(), self) }
        let shift = bitWidth - divisor.bitWidth
        var shifted = divisor.shiftedLeft(by: shift)
        var remainder = self, quotient = Self()
        for bit in stride(from: shift, through: 0, by: -1) {
            if !(remainder < shifted) {
                remainder = remainder - shifted
                quotient.setBit(bit)
            }
            shifted.shiftRightOne()
        }
        return (quotient, remainder)
    }

    static func % (lhs: Self, rhs: Self) -> Self { lhs.quotientAndRemainder(dividingBy: rhs).remainder }

    /// self^exponent mod modulus, left-to-right square and multiply.
    func power(_ exponent: Self, modulus: Self) -> Self {
        var result = Self(1) % modulus
        let base = self % modulus
        for bit in stride(from: exponent.bitWidth - 1, through: 0, by: -1) {
            result = (result * result) % modulus
            if exponent.limbs[bit / 64] >> UInt64(bit % 64) & 1 == 1 {
                result = (result * base) % modulus
            }
        }
        return result
    }

    static func gcd(_ a: Self, _ b: Self) -> Self {
        var (x, y) = (a, b)
        while !y.isZero { (x, y) = (y, x % y) }
        return x
    }

    /// The inverse of self mod modulus, or nil when they share a factor.
    /// Extended Euclid, keeping the coefficient reduced mod modulus so it
    /// never goes negative.
    func inverse(modulus: Self) -> Self? {
        var (oldR, r) = (self % modulus, modulus)
        var (oldT, t) = (Self(1), Self())
        while !r.isZero {
            let (q, rem) = oldR.quotientAndRemainder(dividingBy: r)
            (oldR, r) = (r, rem)
            let qt = (q * t) % modulus
            let next = oldT < qt ? oldT + modulus - qt : oldT - qt
            (oldT, t) = (t, next)
        }
        guard oldR == Self(1) else { return nil }
        return oldT % modulus
    }
}

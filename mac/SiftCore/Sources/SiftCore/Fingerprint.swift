import Foundation

/// A photo's 256-bit difference hash: a 17×16 greyscale version of it, where each bit says
/// whether a pixel is brighter than the one to its left. Re-saved, resized and preview
/// copies of a photo differ by a few bits; unrelated photos by about half of them.
public enum Fingerprint {
    public static let width = 17
    public static let height = 16

    /// The hash of a greyscale image (one byte per pixel, row by row), as 4 numbers, or
    /// nil if the image is blank.
    public static func hash(gray: [UInt8], width: Int, height: Int) -> [UInt64]? {
        guard width > 0, height > 0, gray.count >= width * height else { return nil }
        let px = boxResize(gray: gray, width: width, height: height,
                           toWidth: Self.width, toHeight: Self.height)
        let mean = px.reduce(0, +) / Double(px.count)
        let variance = px.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(px.count)
        if variance.squareRoot() < 1 { return nil }
        var words = [UInt64](repeating: 0, count: 4)
        var bit = 0
        for row in 0..<Self.height {
            for col in 0..<(Self.width - 1) {
                if px[row * Self.width + col + 1] > px[row * Self.width + col] {
                    words[bit / 64] |= 1 << UInt64(63 - bit % 64)   // first bit is the highest
                }
                bit += 1
            }
        }
        return words
    }

    /// How many of the 256 bits differ.
    public static func distance(_ a: [UInt64], _ b: [UInt64]) -> Int {
        (a[0] ^ b[0]).nonzeroBitCount + (a[1] ^ b[1]).nonzeroBitCount
            + (a[2] ^ b[2]).nonzeroBitCount + (a[3] ^ b[3]).nonzeroBitCount
    }

    /// Shrinks an image by averaging the pixels each new pixel covers (counting partly
    /// covered ones in proportion), which is how the fingerprints were calibrated.
    static func boxResize(gray: [UInt8], width: Int, height: Int, toWidth: Int, toHeight: Int) -> [Double] {
        var out = [Double](repeating: 0, count: toWidth * toHeight)
        let sx = Double(width) / Double(toWidth), sy = Double(height) / Double(toHeight)
        for oy in 0..<toHeight {
            let y0 = Double(oy) * sy, y1 = y0 + sy
            for ox in 0..<toWidth {
                let x0 = Double(ox) * sx, x1 = x0 + sx
                var sum = 0.0, area = 0.0
                var y = Int(y0)
                while Double(y) < y1 && y < height {
                    let wy = min(Double(y + 1), y1) - max(Double(y), y0)
                    var x = Int(x0)
                    while Double(x) < x1 && x < width {
                        let w = (min(Double(x + 1), x1) - max(Double(x), x0)) * wy
                        sum += Double(gray[y * width + x]) * w
                        area += w
                        x += 1
                    }
                    y += 1
                }
                out[oy * toWidth + ox] = area > 0 ? sum / area : 0
            }
        }
        return out
    }
}

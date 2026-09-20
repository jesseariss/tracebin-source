import Foundation
import simd

/// binforge.Mesh.write_stl: binary STL with one computed normal per triangle.
enum STLWriter {
    static func data(for mesh: Mesh, name: String = "TraceBin") -> Data {
        let count = mesh.triangleCount
        var out = Data(capacity: 84 + count * 50)

        var header = [UInt8](repeating: 0, count: 80)
        let nameBytes = Array(name.utf8.prefix(80))
        header.replaceSubrange(0..<nameBytes.count, with: nameBytes)
        out.append(contentsOf: header)
        appendUInt32(&out, UInt32(count))

        let v = mesh.vertices
        var i = 0
        while i + 2 < v.count {
            let a = v[i], b = v[i + 1], c = v[i + 2]
            var nrm = simd_cross(b - a, c - a)
            let len = simd_length(nrm)
            nrm = len > 0 ? nrm / len : SIMD3<Float>(0, 0, 0)
            appendFloat(&out, nrm.x); appendFloat(&out, nrm.y); appendFloat(&out, nrm.z)
            for p in [a, b, c] {
                appendFloat(&out, p.x); appendFloat(&out, p.y); appendFloat(&out, p.z)
            }
            appendUInt16(&out, 0)
            i += 3
        }
        return out
    }

    private static func appendFloat(_ d: inout Data, _ value: Float) {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { d.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ d: inout Data, _ value: UInt32) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
    }

    private static func appendUInt16(_ d: inout Data, _ value: UInt16) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
    }
}

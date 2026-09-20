import Foundation
import SwiftData

/// One exported bin. The STL is never stored; it is rebuilt from the outline on demand.
@Model
final class TraceRecord {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var name: String
    var modeRaw: String
    var paperRaw: String
    var clearanceMM: Double
    var heightUnits: Int
    var pocketDepthMM: Double?
    var flatWidthMM: Double?
    var flatDepthMM: Double?
    var flatThicknessMM: Double?
    /// Outline in millimetres, flattened as x0, y0, x1, y1, ...
    var outlineData: Data
    var gridN: Int
    var gridM: Int
    var maskPath: String
    /// Optional for lightweight migration of version 1.0 history. Nil means no notch.
    var notchData: Data?
    /// JPEG of the corrected photo with the outline drawn, 600 px wide.
    @Attribute(.externalStorage) var thumbnail: Data

    init(id: UUID = UUID(), createdAt: Date = Date(), name: String, mode: BinMode, paper: Paper,
         clearanceMM: Double, heightUnits: Int, pocketDepthMM: Double?,
         flatWidthMM: Double?, flatDepthMM: Double?, flatThicknessMM: Double?,
         outlineMM: [Point2], gridN: Int, gridM: Int, maskPath: String, thumbnail: Data) {
        self.id = id
        self.createdAt = createdAt
        self.name = name
        self.modeRaw = mode.rawValue
        self.paperRaw = paper.rawValue
        self.clearanceMM = clearanceMM
        self.heightUnits = heightUnits
        self.pocketDepthMM = pocketDepthMM
        self.flatWidthMM = flatWidthMM
        self.flatDepthMM = flatDepthMM
        self.flatThicknessMM = flatThicknessMM
        self.outlineData = Self.encode(outlineMM)
        self.gridN = gridN
        self.gridM = gridM
        self.maskPath = maskPath
        self.thumbnail = thumbnail
    }

    var mode: BinMode { BinMode(rawValue: modeRaw) ?? .bin }
    var paper: Paper { Paper(rawValue: paperRaw) ?? .letter }

    var outlineMM: [Point2] {
        get { Self.decode(outlineData) }
        set { outlineData = Self.encode(newValue) }
    }

    /// "Bin 4 × 1 × 3u, 167.5 × 41.5 × 21 mm" or "Insert 100 × 100 × 15 mm".
    var sizeLine: String {
        switch mode {
        case .bin:
            return String(format: "Bin %d × %d × %du, %.1f × %.1f × %.0f mm", gridN, gridM, heightUnits,
                          Gridfinity.footprintMM(units: gridN), Gridfinity.footprintMM(units: gridM),
                          Double(heightUnits) * Gridfinity.unitH)
        case .flat:
            return String(format: "Insert %.0f × %.0f × %.0f mm", flatWidthMM ?? 0, flatDepthMM ?? 0, flatThicknessMM ?? 0)
        }
    }

    var fileName: String { name.lowercased().hasSuffix(".stl") ? name : name + ".stl" }
    /// The name without its extension, for lists.
    var displayName: String { name.lowercased().hasSuffix(".stl") ? String(name.dropLast(4)) : name }

    var binSpec: BinSpec {
        BinSpec(outline: outlineMM, mode: mode, heightUnits: heightUnits, pocketDepthMM: pocketDepthMM,
                flatWidthMM: flatWidthMM ?? 100, flatDepthMM: flatDepthMM ?? 100, flatThicknessMM: flatThicknessMM ?? 15,
                fileName: fileName, summaryLine: sizeLine + ".", notch: notch)
    }

    var notch: FingerNotch? {
        get { notchData.flatMap { try? JSONDecoder().decode(FingerNotch.self, from: $0) } }
        set { notchData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    /// Save accepted edits independently of export. Restore only this field if saving fails.
    func saveNotch(_ value: FingerNotch?, save: () throws -> Void) throws {
        let previous = notchData
        notch = value
        do { try save() }
        catch { notchData = previous; throw error }
    }

    private static func encode(_ pts: [Point2]) -> Data {
        var flat: [Double] = []
        flat.reserveCapacity(pts.count * 2)
        for p in pts {
            flat.append(p.x)
            flat.append(p.y)
        }
        return flat.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func decode(_ data: Data) -> [Point2] {
        let count = data.count / MemoryLayout<Double>.size
        var flat = [Double](repeating: 0, count: count)
        _ = flat.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        var pts: [Point2] = []
        pts.reserveCapacity(count / 2)
        var i = 0
        while i + 1 < count {
            pts.append(Point2(flat[i], flat[i + 1]))
            i += 2
        }
        return pts
    }
}

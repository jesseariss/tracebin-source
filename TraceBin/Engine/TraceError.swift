import Foundation

/// The three user-facing failures, plus one catch-all for things that should never happen.
enum TraceError: LocalizedError {
    case paperNotFound
    case toolNotSeparable
    case toolTooLarge
    case internalFailure(String)

    var errorDescription: String? {
        switch self {
        case .paperNotFound:
            return "Could not find the sheet of paper. Keep the whole sheet in the photo with all four corners visible, and try a plain background if the surface is busy."
        case .toolNotSeparable:
            return "Could not separate the tool from the paper. Try a darker or lighter background."
        case .toolTooLarge:
            return "The tool is larger than the sheet. Use a bigger sheet or a smaller tool."
        case .internalFailure(let detail):
            return "Something went wrong while processing the photo (\(detail))."
        }
    }
}

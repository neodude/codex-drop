#if canImport(UIKit)
import UIKit

/// Shared native iPhone appearance; protocol and client checks remain UI-free.
@MainActor enum DropBrand {
    static let transferBackground = UIColor(red: 16/255, green: 16/255, blue: 20/255, alpha: 1)
    static let transferSurface = UIColor(red: 27/255, green: 27/255, blue: 34/255, alpha: 1)
    static let ink = UIColor(red: 244/255, green: 244/255, blue: 247/255, alpha: 1)
    static let secondary = UIColor(red: 179/255, green: 179/255, blue: 191/255, alpha: 1)
    static let aquamarine = UIColor(red: 47/255, green: 1, blue: 211/255, alpha: 1)
    static let mint = UIColor(red: 105/255, green: 213/255, blue: 193/255, alpha: 1)
    // Deep aquamarine keeps system Paste controls’ white label readable.
    // Bright aquamarine is reserved for dark backgrounds; light links use teal.
    static let filledAccent = UIColor(red: 0, green: 116/255, blue: 96/255, alpha: 1)
    static let accent = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 47/255, green: 1, blue: 211/255, alpha: 1)
            : UIColor(red: 0, green: 116/255, blue: 96/255, alpha: 1)
    }
}
#endif

#if canImport(UIKit)
import UIKit

/// Shared native iPhone appearance; protocol and client checks remain UI-free.
@MainActor enum DropBrand {
    static let transferBackground = UIColor(red: 16/255, green: 16/255, blue: 20/255, alpha: 1)
    static let transferSurface = UIColor(red: 27/255, green: 27/255, blue: 34/255, alpha: 1)
    static let ink = UIColor(red: 244/255, green: 244/255, blue: 247/255, alpha: 1)
    static let secondary = UIColor(red: 179/255, green: 179/255, blue: 191/255, alpha: 1)
    static let lavender = UIColor(red: 179/255, green: 185/255, blue: 1, alpha: 1)
    static let mint = UIColor(red: 105/255, green: 213/255, blue: 193/255, alpha: 1)
    // Filled system paste controls retain a white label in either appearance.
    static let filledAccent = UIColor(red: 86/255, green: 95/255, blue: 219/255, alpha: 1)
    static let accent = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 179/255, green: 185/255, blue: 1, alpha: 1)
            : UIColor(red: 86/255, green: 95/255, blue: 219/255, alpha: 1)
    }
}
#endif

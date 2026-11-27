import UIKit

extension UIApplication {
    /// Puts the keyboard away without ending the search or editing state.
    func dismissKeyboard() {
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

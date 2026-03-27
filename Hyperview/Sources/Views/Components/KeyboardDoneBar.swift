import SwiftUI
import UIKit

// MARK: - Global Done Bar Setup

/// Call once at app launch to install a "Done" button above every keyboard.
/// Uses NotificationCenter to detect text field activation and attach an inputAccessoryView.
enum KeyboardDoneBarSetup {
    private static var installed = false
    private static var observers: [Any] = []

    /// Walk the responder chain to check if a view lives inside a WKWebView.
    private static func isInsideWKWebView(_ view: UIView) -> Bool {
        var current: UIView? = view.superview
        while let v = current {
            if String(describing: type(of: v)).contains("WKWebView") ||
               String(describing: type(of: v)).contains("WKContentView") {
                return true
            }
            current = v.superview
        }
        return false
    }

    static func install() {
        guard !installed else { return }
        installed = true

        let nc = NotificationCenter.default

        // UITextField — fires when any text field in the app begins editing.
        // Skip WKWebView internal fields — they trigger the Done bar without a keyboard.
        observers.append(nc.addObserver(
            forName: UITextField.textDidBeginEditingNotification,
            object: nil, queue: .main
        ) { note in
            guard let tf = note.object as? UITextField,
                  !Self.isInsideWKWebView(tf) else { return }
            if tf.inputAccessoryView == nil || tf.inputAccessoryView is DoneAccessoryBar == false {
                tf.inputAccessoryView = DoneAccessoryBar()
                tf.reloadInputViews()
            }
        })

        // UITextView — fires when any text view in the app begins editing.
        // Skip WKWebView internal fields.
        observers.append(nc.addObserver(
            forName: UITextView.textDidBeginEditingNotification,
            object: nil, queue: .main
        ) { note in
            guard let tv = note.object as? UITextView,
                  !Self.isInsideWKWebView(tv) else { return }
            if tv.inputAccessoryView == nil || tv.inputAccessoryView is DoneAccessoryBar == false {
                tv.inputAccessoryView = DoneAccessoryBar()
                tv.reloadInputViews()
            }
        })
    }
}

/// Toolbar with a single "Done" button that dismisses the keyboard.
/// Uses an opaque dark background matching the app theme to avoid translucent black veil artifacts.
private class DoneAccessoryBar: UIToolbar {
    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 44))

        // Opaque dark background — matches app theme, no translucent veil
        let appearance = UIToolbarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1) // matches keyboard bg
        appearance.shadowColor = .clear // no top border line
        standardAppearance = appearance
        scrollEdgeAppearance = appearance
        compactAppearance = appearance

        sizeToFit()

        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let done = UIBarButtonItem(title: "Done", style: .done, target: self, action: #selector(dismissKeyboard))
        done.tintColor = UIColor(red: 0.145, green: 0.839, blue: 0.584, alpha: 1) // hlGreen
        done.setTitleTextAttributes([
            .font: UIFont.boldSystemFont(ofSize: 17),
            .foregroundColor: UIColor(red: 0.145, green: 0.839, blue: 0.584, alpha: 1)
        ], for: .normal)
        items = [flex, done]
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }
}

// MARK: - Legacy modifier (kept for compatibility — now a no-op)

struct KeyboardDoneBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
    }
}

extension View {
    func keyboardDoneBar() -> some View {
        modifier(KeyboardDoneBarModifier())
    }
}

// MARK: - Comma Formatting for Number Inputs

private func addThousandCommas(_ digits: String) -> String {
    guard !digits.isEmpty else { return "" }
    var result = ""
    for (i, ch) in digits.reversed().enumerated() {
        if i > 0 && i % 3 == 0 { result.append(",") }
        result.append(ch)
    }
    return String(result.reversed())
}

func formatIntegerWithCommas(_ text: String) -> String {
    let digits = text.filter { $0.isNumber }
    guard !digits.isEmpty else { return "" }
    let trimmed = String(digits.drop { $0 == "0" })
    return addThousandCommas(trimmed.isEmpty ? "0" : trimmed)
}

func formatDecimalWithCommas(_ text: String) -> String {
    let cleaned = text.replacingOccurrences(of: ",", with: "")
    let parts = cleaned.components(separatedBy: ".")
    let intDigits = parts[0].filter { $0.isNumber }

    guard !intDigits.isEmpty else {
        if cleaned.hasPrefix(".") { return "0." + cleaned.dropFirst().filter { $0.isNumber } }
        return ""
    }

    let trimmed = String(intDigits.drop { $0 == "0" })
    var result = addThousandCommas(trimmed.isEmpty ? "0" : trimmed)

    if parts.count > 1 {
        result += "." + parts[1].filter { $0.isNumber }
    }
    return result
}

func formatDecimalOnChange(oldValue: String, newValue: String) -> String {
    var text = newValue

    if !newValue.contains(".") && newValue.contains(",") {
        let oldDigits = oldValue.filter(\.isNumber).count
        let newDigits = newValue.filter(\.isNumber).count

        if newDigits == oldDigits && !oldValue.contains(".") {
            if let lastComma = newValue.lastIndex(of: ",") {
                var chars = Array(text)
                let idx = text.distance(from: text.startIndex, to: lastComma)
                chars[idx] = "."
                text = String(chars)
            }
        }
    }

    return formatDecimalWithCommas(text)
}

func convertLocaleComma(_ text: String) -> String {
    guard !text.contains(".") else { return text }
    let digitCount = text.filter { $0.isNumber }.count
    let expectedCommas = digitCount > 3 ? (digitCount - 1) / 3 : 0
    let actualCommas = text.filter { $0 == "," }.count
    guard actualCommas > expectedCommas, let last = text.lastIndex(of: ",") else { return text }
    var result = text
    result.replaceSubrange(last...last, with: ".")
    return result
}

func stripCommas(_ text: String) -> String {
    text.replacingOccurrences(of: ",", with: "")
}

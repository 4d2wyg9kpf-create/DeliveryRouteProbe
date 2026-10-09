import SwiftUI

// A UIKit text field with an editable string buffer. Empty text is
// allowed during deletion; formatting must not put a digit back on every key.
struct IntegerInput: View {
    let title: String
    @Binding var value: Int
    @State private var draft: String
    @State private var isEditing = false

    init(title: String, value: Binding<Int>) {
        self.title = title
        _value = value
        _draft = State(initialValue: String(value.wrappedValue))
    }

    private var text: Binding<String> {
        Binding(get: { draft }, set: { incoming in
            // Numeric pad input and numeric paste both use the same validation.
            // Reject malformed/overflowing text rather than silently saving a
            // different number. A cleared field represents zero in the model.
            guard incoming.isEmpty || incoming.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return }
            guard let number = incoming.isEmpty ? 0 : Int(incoming) else { return }
            draft = incoming
            value = number
        })
    }

    var body: some View {
        NativeTextField(title, text: text, keyboard: .numberPad,
                        alignment: .right, digitsOnly: true) { editing in
            isEditing = editing
            if !editing { draft = String(value) }
        }
            .onChange(of: value) { next in
                if !isEditing { draft = String(next) }
            }
    }
}

import SwiftUI
import UIKit

// The input controls follow M4Download 0.5.0's NativeAddressField and
// SourceTextInput. UIKit owns selection, marked text and ordinary tap-to-edit.
// This owner only commits the current control for explicit Save/Close actions.
@MainActor
final class NativeInputSession: ObservableObject {
    private weak var active: UIView?

    func began(_ view: UIView) { active = view }
    func ended(_ view: UIView) {
        if active === view { active = nil }
    }

    func finishEditing() {
        guard let view = active else { return }
        if let field = view as? UITextField {
            field.unmarkText()
            field.sendActions(for: .editingChanged)
        } else if let editor = view as? UITextView {
            editor.unmarkText()
            editor.delegate?.textViewDidChange?(editor)
        }
        view.resignFirstResponder()
        ended(view)
    }
}

@MainActor
struct NativeTextField: UIViewRepresentable {
    let title: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var alignment: NSTextAlignment = .natural
    var digitsOnly = false
    var onEditingChanged: (Bool) -> Void = { _ in }
    @EnvironmentObject private var inputs: NativeInputSession

    init(_ title: String, text: Binding<String>, keyboard: UIKeyboardType = .default,
         alignment: NSTextAlignment = .natural, digitsOnly: Bool = false,
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.title = title
        self._text = text
        self.keyboard = keyboard
        self.alignment = alignment
        self.digitsOnly = digitsOnly
        self.onEditingChanged = onEditingChanged
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> DeliveryTextField {
        let field = DeliveryTextField()
        field.borderStyle = .roundedRect
        field.placeholder = title
        field.keyboardType = keyboard
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.returnKeyType = .done
        field.clearButtonMode = .whileEditing
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.textAlignment = alignment
        field.accessibilityLabel = title
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: DeliveryTextField, context: Context) {
        context.coordinator.parent = self
        // Same guard as the working address field: a redraw does not replace
        // marked text or reset the cursor when the value hasn't changed.
        if field.markedTextRange == nil, field.text != text { field.text = text }
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: NativeTextField
        init(_ parent: NativeTextField) { self.parent = parent }
        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }

        func textFieldDidBeginEditing(_ field: UITextField) {
            parent.inputs.began(field)
            parent.onEditingChanged(true)
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            changed(field)
            parent.inputs.ended(field)
            parent.onEditingChanged(false)
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            field.resignFirstResponder()
            return true
        }

        func textField(_ field: UITextField, shouldChangeCharactersIn range: NSRange,
                       replacementString string: String) -> Bool {
            guard parent.digitsOnly else { return true }
            let current = field.text ?? ""
            guard let swiftRange = Range(range, in: current) else { return false }
            let next = current.replacingCharacters(in: swiftRange, with: string)
            return next.isEmpty || (next.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } && Int(next) != nil)
        }
    }
}

final class DeliveryTextField: UITextField {
    // This is the working NativeAddressField's touch handling. In particular,
    // do not override hitTest or becomeFirstResponder as the 0.2.1 port did.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if isEnabled, let window, !window.isKeyWindow { window.makeKey() }
        super.touchesBegan(touches, with: event)
    }
}

@MainActor
struct NativeMemoEditor: UIViewControllerRepresentable {
    @Binding var text: String
    @EnvironmentObject private var inputs: NativeInputSession

    func makeUIViewController(context: Context) -> DeliveryMemoController {
        let controller = DeliveryMemoController()
        update(controller)
        return controller
    }

    func updateUIViewController(_ controller: DeliveryMemoController, context: Context) {
        update(controller)
    }

    private func update(_ controller: DeliveryMemoController) {
        controller.inputs = inputs
        controller.onTextChange = { text = $0 }
        controller.setText(text)
    }
}

final class DeliveryMemoController: UIViewController, UITextViewDelegate {
    private let editor = UITextView()
    weak var inputs: NativeInputSession?
    var onTextChange: ((String) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        editor.delegate = self
        editor.isEditable = true
        editor.isSelectable = true
        editor.isUserInteractionEnabled = true
        editor.font = .preferredFont(forTextStyle: .body)
        editor.adjustsFontForContentSizeCategory = true
        editor.textColor = .label
        editor.backgroundColor = .secondarySystemGroupedBackground
        editor.tintColor = .systemBlue
        editor.autocorrectionType = .no
        editor.autocapitalizationType = .none
        editor.spellCheckingType = .no
        editor.smartQuotesType = .no
        editor.smartDashesType = .no
        editor.smartInsertDeleteType = .no
        editor.keyboardType = .default
        editor.accessibilityLabel = "메모"
        editor.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        editor.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(editor)
        NSLayoutConstraint.activate([
            editor.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            editor.topAnchor.constraint(equalTo: view.topAnchor),
            editor.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    // The source app has one editor and automatically focuses it on appear.
    // This form has several fields; the memo must not steal their focus when
    // it scrolls onscreen or the app resumes. UIKit handles the user's tap.
    override func viewWillDisappear(_ animated: Bool) {
        editor.resignFirstResponder()
        super.viewWillDisappear(animated)
    }

    func setText(_ text: String) {
        guard editor.text != text, editor.markedTextRange == nil else { return }
        let selection = editor.selectedRange
        editor.text = text
        let length = (text as NSString).length
        let location = min(selection.location, length)
        editor.selectedRange = NSRange(location: location, length: min(selection.length, length - location))
    }

    func textViewDidBeginEditing(_ textView: UITextView) { inputs?.began(textView) }
    func textViewDidChange(_ textView: UITextView) { onTextChange?(textView.text) }
    func textViewDidEndEditing(_ textView: UITextView) {
        textViewDidChange(textView)
        inputs?.ended(textView)
    }
}

import AppKit
import SwiftUI

struct TerminalNativeSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var font: NSFont = .systemFont(ofSize: 13)
    var focusOnAppear = true
    var focusToken: Int = 0
    var selectAllOnFocus = false
    var onArrowDown: (() -> Void)? = nil
    var onArrowUp: (() -> Void)? = nil
    var onReturn: (() -> Void)? = nil
    var onShiftReturn: (() -> Void)? = nil
    var onEscape: (() -> Void)? = nil
    var onTextDidChange: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSSearchField {
        let field = TerminalKeyAwareSearchField()
        field.placeholderString = placeholder
        field.controlSize = .regular
        field.font = font
        field.delegate = context.coordinator
        field.focusRingType = .default
        field.onArrowDown = onArrowDown
        field.onArrowUp = onArrowUp
        field.onReturn = onReturn
        field.onShiftReturn = onShiftReturn
        field.onEscape = onEscape

        if focusOnAppear {
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
            }
        }

        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }

        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                guard let window = nsView.window else { return }
                window.makeFirstResponder(nsView)
                if selectAllOnFocus {
                    nsView.selectText(nil)
                }
            }
        }

        context.coordinator.onArrowDown = onArrowDown
        context.coordinator.onArrowUp = onArrowUp
        context.coordinator.onReturn = onReturn
        context.coordinator.onShiftReturn = onShiftReturn
        context.coordinator.onEscape = onEscape
        context.coordinator.onTextDidChange = onTextDidChange

        if let field = nsView as? TerminalKeyAwareSearchField {
            field.onArrowDown = onArrowDown
            field.onArrowUp = onArrowUp
            field.onReturn = onReturn
            field.onShiftReturn = onShiftReturn
            field.onEscape = onEscape
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onTextDidChange: onTextDidChange)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        @Binding var text: String
        var onArrowDown: (() -> Void)?
        var onArrowUp: (() -> Void)?
        var onReturn: (() -> Void)?
        var onShiftReturn: (() -> Void)?
        var onEscape: (() -> Void)?
        var onTextDidChange: (() -> Void)?
        var lastFocusToken: Int

        init(text: Binding<String>, onTextDidChange: (() -> Void)?) {
            _text = text
            self.onTextDidChange = onTextDidChange
            self.lastFocusToken = 0
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text = field.stringValue
            onTextDidChange?()
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)):
                guard let onArrowDown else { return false }
                onArrowDown()
                return true
            case #selector(NSResponder.moveUp(_:)):
                guard let onArrowUp else { return false }
                onArrowUp()
                return true
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertLineBreak(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                let modifiers = NSApp.currentEvent?.modifierFlags ?? []
                if modifiers.contains(.shift), let onShiftReturn {
                    onShiftReturn()
                    return true
                }
                guard let onReturn else { return false }
                onReturn()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                guard let onEscape else { return false }
                onEscape()
                return true
            default:
                return false
            }
        }
    }
}

private final class TerminalKeyAwareSearchField: NSSearchField {
    var onArrowDown: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onReturn: (() -> Void)?
    var onShiftReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: // down arrow
            onArrowDown?()
            return
        case 126: // up arrow
            onArrowUp?()
            return
        case 36: // return
            if event.modifierFlags.contains(.shift) {
                onShiftReturn?()
            } else {
                onReturn?()
            }
            return
        case 53: // escape
            onEscape?()
            return
        default:
            super.keyDown(with: event)
        }
    }
}

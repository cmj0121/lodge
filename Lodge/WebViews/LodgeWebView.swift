import AppKit
import WebKit

/// WKWebView whose context menu offers "Open Link in New Tab" in place of WebKit's
/// "Open Link in New Window". The item still runs WebKit's own action, so the link arrives through
/// `createWebViewWith` with the opener's configuration and opens as the live tab.
final class LodgeWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        let newWindow = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLinkInNewWindow")
        guard let index = menu.items.firstIndex(where: { $0.identifier == newWindow }) else { return }
        let original = menu.items[index]
        let item = NSMenuItem(title: "Open Link in New Tab", action: #selector(openLinkInNewTab(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = original
        menu.removeItem(at: index)
        menu.insertItem(item, at: index)
    }

    @objc private func openLinkInNewTab(_ sender: NSMenuItem) {
        guard let original = sender.representedObject as? NSMenuItem, let action = original.action else { return }
        NSApp.sendAction(action, to: original.target, from: original)
    }
}

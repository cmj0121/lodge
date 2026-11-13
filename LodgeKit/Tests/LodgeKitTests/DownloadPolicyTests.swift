import Testing

@testable import LodgeKit

@Suite struct DownloadPolicyTests {
    @Test func aResponseTheViewCannotShowDownloadsInAnyFrame() {
        #expect(DownloadPolicy.shouldDownload(mimeCanShow: false, contentDisposition: nil, isMainFrame: true))
        #expect(DownloadPolicy.shouldDownload(mimeCanShow: false, contentDisposition: "inline", isMainFrame: false))
    }

    @Test(arguments: [
        "attachment", "Attachment", "ATTACHMENT; filename=a.zip", "  attachment ;filename*=UTF-8''a.zip",
    ])
    func anAttachmentInTheMainFrameDownloads(_ disposition: String) {
        #expect(DownloadPolicy.shouldDownload(mimeCanShow: true, contentDisposition: disposition, isMainFrame: true))
    }

    @Test func anAttachmentInASubframeShowsWhenItCan() {
        #expect(!DownloadPolicy.shouldDownload(mimeCanShow: true, contentDisposition: "attachment", isMainFrame: false))
    }

    @Test func anAttachmentASubframeLinkClickAskedForDownloads() {
        #expect(
            DownloadPolicy.shouldDownload(
                mimeCanShow: true, contentDisposition: "attachment", isMainFrame: false, userInitiated: true))
        #expect(
            !DownloadPolicy.shouldDownload(
                mimeCanShow: true, contentDisposition: "inline", isMainFrame: false, userInitiated: true))
    }

    @Test(arguments: [nil, "", "inline", "inline; filename=attachment", "attachments", "form-data; name=attachment"])
    func anythingElseThatCanShowShows(_ disposition: String?) {
        #expect(!DownloadPolicy.shouldDownload(mimeCanShow: true, contentDisposition: disposition, isMainFrame: true))
    }
}

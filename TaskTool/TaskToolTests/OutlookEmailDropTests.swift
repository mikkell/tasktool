import XCTest
@testable import TaskTool

final class OutlookEmailDropTests: XCTestCase {
    func testParsesPlainTextBody() throws {
        let email = """
        From: Alex Example <alex@example.com>
        Subject: Review the contract
        Date: Fri, 9 Oct 2026 10:00:00 +0200
        MIME-Version: 1.0
        Content-Type: text/plain; charset=UTF-8

        Please review the attached contract.
        """

        let message = try OutlookEmailMessage(data: Data(email.utf8))

        XCTAssertEqual(message.subject, "Review the contract")
        XCTAssertEqual(message.sender, "Alex Example <alex@example.com>")
        XCTAssertEqual(message.date, "Fri, 9 Oct 2026 10:00:00 +0200")
        XCTAssertEqual(message.body, "Please review the attached contract.")
        XCTAssertEqual(
            message.taskBody,
            "Captured from Outlook.\nFrom: Alex Example <alex@example.com>\nDate: Fri, 9 Oct 2026 10:00:00 +0200\n\nEmail body:\nPlease review the attached contract."
        )
    }

    func testParsesEncodedAndFoldedHeadersAndQuotedPrintableBody() throws {
        let email = """
        From: =?UTF-8?Q?Alex_Example?=
         <alex@example.com>
        Subject: =?UTF-8?Q?R=C3=A9sum=C3=A9?=
        Content-Type: text/plain; charset=UTF-8
        Content-Transfer-Encoding: quoted-printable

        Caf=C3=A9=20meeting=21
        """

        let message = try OutlookEmailMessage(data: Data(email.utf8))

        XCTAssertEqual(message.subject, "Résumé")
        XCTAssertEqual(message.sender, "Alex Example <alex@example.com>")
        XCTAssertEqual(message.body, "Café meeting!")
    }

    func testDecodesBase64TextBody() throws {
        let email = """
        Subject: Encoded message
        Content-Type: text/plain; charset=UTF-8
        Content-Transfer-Encoding: base64

        SGVsbG8gZnJvbSBPdXRsb29rLg==
        """

        let message = try OutlookEmailMessage(data: Data(email.utf8))

        XCTAssertEqual(message.body, "Hello from Outlook.")
    }

    func testPrefersPlainTextAndExcludesAttachmentsInMultipartEmail() throws {
        let email = """
        From: Alex <alex@example.com>
        Subject: Multipart message
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="outer-boundary"

        --outer-boundary
        Content-Type: multipart/alternative; boundary="alternative-boundary"

        --alternative-boundary
        Content-Type: text/plain; charset=UTF-8

        Plain text body.
        --alternative-boundary
        Content-Type: text/html; charset=UTF-8

        <p>HTML body.</p>
        --alternative-boundary--
        --outer-boundary
        Content-Type: application/octet-stream
        Content-Disposition: attachment; filename="secret.txt"
        Content-Transfer-Encoding: base64

        c2VjcmV0IGF0dGFjaG1lbnQ=
        --outer-boundary--
        """

        let message = try OutlookEmailMessage(data: Data(email.utf8))

        XCTAssertEqual(message.body, "Plain text body.")
        XCTAssertFalse(message.taskBody.contains("HTML body"))
        XCTAssertFalse(message.taskBody.contains("secret attachment"))
    }

    func testParsesContinuedMultipartBoundaryParameter() throws {
        let email = """
        Subject: Continued boundary
        Content-Type: multipart/alternative; boundary*0*=utf-8''outer; boundary*1*=-boundary

        --outer-boundary
        Content-Type: text/plain; charset=UTF-8

        Boundary parsed.
        --outer-boundary--
        """

        let message = try OutlookEmailMessage(data: Data(email.utf8))

        XCTAssertEqual(message.body, "Boundary parsed.")
    }

    func testInfersMissingMultipartBoundaryFromMatchingDelimiters() throws {
        let email = """
        Subject: Missing boundary parameter
        Content-Type: multipart/alternative

        --outlook-boundary
        Content-Type: text/plain; charset=UTF-8

        Inferred boundary body.
        --outlook-boundary--
        """

        let message = try OutlookEmailMessage(data: Data(email.utf8))

        XCTAssertEqual(message.body, "Inferred boundary body.")
    }

    func testConvertsHTMLBodyWhenPlainTextIsUnavailable() throws {
        let email = """
        From: Alex <alex@example.com>
        Subject: HTML message
        Content-Type: text/html; charset=UTF-8

        <html><body><p>Hello&nbsp;<strong>there</strong>.</p><p>Next line &amp; more.</p></body></html>
        """

        let message = try OutlookEmailMessage(data: Data(email.utf8))

        XCTAssertEqual(message.body, "Hello there.\nNext line & more.")
    }

    func testTruncatesVeryLongBody() throws {
        let body = String(repeating: "a", count: 20_010)
        let email = "Subject: Long message\nContent-Type: text/plain; charset=UTF-8\n\n\(body)"

        let message = try OutlookEmailMessage(data: Data(email.utf8))

        XCTAssertEqual(message.body?.count, 20_000)
        XCTAssertTrue(message.bodyWasTruncated)
        XCTAssertTrue(message.taskBody.hasSuffix("[Email body truncated.]"))
    }

    func testRejectsDataThatIsNotAnEmailMessage() {
        XCTAssertThrowsError(try OutlookEmailMessage(data: Data("not an email".utf8))) { error in
            XCTAssertEqual(error as? OutlookEmailDropError, .invalidEmailFile)
        }
    }

    func testRequiresEmailSubject() {
        let email = "From: alex@example.com\n\nBody"

        XCTAssertThrowsError(try OutlookEmailMessage(data: Data(email.utf8))) { error in
            XCTAssertEqual(error as? OutlookEmailDropError, .missingSubject)
        }
    }

    func testReportsSafeDiagnosticWhenNoReadableBodyIsPresent() throws {
        let email = "Subject: Headers only\nContent-Type: application/octet-stream\n\nbinary"

        let message = try OutlookEmailMessage(data: Data(email.utf8))

        XCTAssertNil(message.body)
        XCTAssertEqual(
            message.bodyDiagnostic,
            "No readable text body found (application/octet-stream, transfer: none, bytes: 6)."
        )
    }
}

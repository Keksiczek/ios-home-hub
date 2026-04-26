import XCTest
@testable import HomeHub

/// Pins down the block-level parser inside `InlineMarkdownColumn`.
/// The previous implementation rendered everything via
/// `.inlineOnlyPreservingWhitespace`, so headings and lists shipped to
/// the user as literal `## ` / `- ` text. These tests guard against
/// regressing into that state and document the supported subset.
final class MarkdownContentTests: XCTestCase {

    // MARK: - Headings

    func testParsesH1H2H3H4() {
        let blocks = InlineBlock.parse("""
        # One
        ## Two
        ### Three
        #### Four
        """)
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "One"),
            .heading(level: 2, text: "Two"),
            .heading(level: 3, text: "Three"),
            .heading(level: 4, text: "Four")
        ])
    }

    func testHashWithoutSpaceIsNotAHeading() {
        // `#tag` is a hashtag, not a heading. Without this guard the
        // parser would eat user-facing copy that uses `#` for emphasis.
        let blocks = InlineBlock.parse("#tag value")
        XCTAssertEqual(blocks, [.paragraph(text: "#tag value")])
    }

    // MARK: - Bullet lists

    func testGroupsConsecutiveBulletsIntoOneList() {
        let blocks = InlineBlock.parse("""
        - one
        - two
        - three
        """)
        XCTAssertEqual(blocks, [.bullet(items: ["one", "two", "three"])])
    }

    func testAcceptsAsteriskAndPlusBullets() {
        let blocks = InlineBlock.parse("""
        * star
        + plus
        - dash
        """)
        // Mixed markers in one block is unusual but parser still groups
        // them — matches GitHub-flavored markdown lenient behavior.
        XCTAssertEqual(blocks, [.bullet(items: ["star", "plus", "dash"])])
    }

    // MARK: - Ordered lists

    func testParsesNumberedList() {
        let blocks = InlineBlock.parse("""
        1. First
        2. Second
        10. Tenth
        """)
        XCTAssertEqual(blocks, [.ordered(items: ["First", "Second", "Tenth"])])
    }

    func testAcceptsParenthesisOrderedSyntax() {
        let blocks = InlineBlock.parse("""
        1) Alpha
        2) Beta
        """)
        XCTAssertEqual(blocks, [.ordered(items: ["Alpha", "Beta"])])
    }

    func testOneDotFiveIsNotAListItem() {
        // Decimal numbers in prose ("the 1.5x speedup") would otherwise
        // get classified as ordered-list items because they start with
        // "1." We require a space after the marker dot to avoid that.
        let blocks = InlineBlock.parse("the 1.5x speedup")
        XCTAssertEqual(blocks, [.paragraph(text: "the 1.5x speedup")])
    }

    // MARK: - Blockquotes

    func testParsesBlockquote() {
        let blocks = InlineBlock.parse("> a wise saying")
        XCTAssertEqual(blocks, [.quote(text: "a wise saying")])
    }

    func testJoinsConsecutiveQuoteLines() {
        let blocks = InlineBlock.parse("""
        > line one
        > line two
        """)
        XCTAssertEqual(blocks, [.quote(text: "line one\nline two")])
    }

    // MARK: - Paragraphs

    func testJoinsConsecutiveTextLinesIntoOneParagraph() {
        let blocks = InlineBlock.parse("""
        First line.
        Second line.
        """)
        XCTAssertEqual(blocks, [.paragraph(text: "First line.\nSecond line.")])
    }

    func testEmptyLineSplitsParagraphs() {
        let blocks = InlineBlock.parse("""
        First.

        Second.
        """)
        XCTAssertEqual(blocks, [
            .paragraph(text: "First."),
            .paragraph(text: "Second.")
        ])
    }

    // MARK: - Mixed content (the realistic case)

    func testHeadingFollowedByList() {
        let blocks = InlineBlock.parse("""
        ## Steps
        - Boot the device
        - Install the app
        - Run inference
        """)
        XCTAssertEqual(blocks, [
            .heading(level: 2, text: "Steps"),
            .bullet(items: ["Boot the device", "Install the app", "Run inference"])
        ])
    }

    func testListThenParagraphThenList() {
        let blocks = InlineBlock.parse("""
        - one
        - two

        Some prose between the lists.

        1. alpha
        2. beta
        """)
        XCTAssertEqual(blocks, [
            .bullet(items: ["one", "two"]),
            .paragraph(text: "Some prose between the lists."),
            .ordered(items: ["alpha", "beta"])
        ])
    }

    // MARK: - Empty input

    func testEmptyStringYieldsNoBlocks() {
        XCTAssertEqual(InlineBlock.parse(""), [])
    }

    func testWhitespaceOnlyYieldsNoBlocks() {
        XCTAssertEqual(InlineBlock.parse("   \n\n  \n"), [])
    }
}

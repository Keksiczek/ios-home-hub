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

    // MARK: - Tables

    func testParsesBasicTable() {
        let blocks = InlineBlock.parse("""
        | Name | Size |
        |------|------|
        | Foo  | 1 MB |
        | Bar  | 2 MB |
        """)
        XCTAssertEqual(blocks, [
            .table(
                headers: ["Name", "Size"],
                rows: [["Foo", "1 MB"], ["Bar", "2 MB"]]
            )
        ])
    }

    func testParsesTableWithoutOuterPipes() {
        // GFM allows tables without leading/trailing pipes — small models
        // sometimes drop them, especially when streaming token by token.
        let blocks = InlineBlock.parse("""
        Name | Size
        ---  | ---
        Foo  | 1 MB
        Bar  | 2 MB
        """)
        XCTAssertEqual(blocks, [
            .table(
                headers: ["Name", "Size"],
                rows: [["Foo", "1 MB"], ["Bar", "2 MB"]]
            )
        ])
    }

    func testParsesTableWithAlignmentColons() {
        // `:---`, `---:`, and `:---:` are alignment hints in GFM. The
        // parser should accept the separator regardless of alignment
        // direction (we ignore the hint at render time — small models
        // misuse it more often than they get it right).
        let blocks = InlineBlock.parse("""
        | Left | Center | Right |
        | :--- | :---:  | ---:  |
        | a    | b      | c     |
        """)
        XCTAssertEqual(blocks, [
            .table(
                headers: ["Left", "Center", "Right"],
                rows: [["a", "b", "c"]]
            )
        ])
    }

    func testTableWithoutSeparatorIsNotATable() {
        // Without the separator row, a string with pipes is just prose
        // ("dog | cat | mouse"). Without this guard the parser would
        // hijack any sentence containing two pipes.
        let blocks = InlineBlock.parse("dog | cat | mouse")
        XCTAssertEqual(blocks, [.paragraph(text: "dog | cat | mouse")])
    }

    func testTableEndsAtFirstNonPipeLine() {
        // Anything that doesn't contain a pipe terminates the table —
        // even a paragraph immediately after, without a blank line.
        let blocks = InlineBlock.parse("""
        | A | B |
        |---|---|
        | 1 | 2 |
        After the table.
        """)
        XCTAssertEqual(blocks, [
            .table(headers: ["A", "B"], rows: [["1", "2"]]),
            .paragraph(text: "After the table.")
        ])
    }

    func testTableSeparatorOnly() {
        // Header + separator with no body rows is still a valid (empty)
        // table — the model probably hasn't emitted the rows yet during
        // streaming. Render the headers, no body.
        let blocks = InlineBlock.parse("""
        | A | B |
        |---|---|
        """)
        XCTAssertEqual(blocks, [.table(headers: ["A", "B"], rows: [])])
    }

    // MARK: - Horizontal rule

    func testThreeDashRule() {
        XCTAssertEqual(InlineBlock.parse("---"), [.horizontalRule])
    }

    func testThreeAsteriskRule() {
        XCTAssertEqual(InlineBlock.parse("***"), [.horizontalRule])
    }

    func testThreeUnderscoreRule() {
        XCTAssertEqual(InlineBlock.parse("___"), [.horizontalRule])
    }

    func testRuleWithSpaces() {
        XCTAssertEqual(InlineBlock.parse("- - -"), [.horizontalRule])
    }

    func testTwoDashesIsNotARule() {
        // Two dashes is too short — common in prose ("--option") and
        // shouldn't be promoted to a structural break.
        XCTAssertEqual(InlineBlock.parse("--"), [.paragraph(text: "--")])
    }

    func testMixedMarkersIsNotARule() {
        XCTAssertEqual(InlineBlock.parse("---***"), [.paragraph(text: "---***")])
    }

    func testRuleSeparatesParagraphs() {
        let blocks = InlineBlock.parse("""
        Above the line.

        ---

        Below the line.
        """)
        XCTAssertEqual(blocks, [
            .paragraph(text: "Above the line."),
            .horizontalRule,
            .paragraph(text: "Below the line.")
        ])
    }

    // MARK: - Helper functions (parser internals)

    func testParseTableRowStripsWrappingPipes() {
        XCTAssertEqual(InlineBlock.parseTableRow("| a | b | c |"), ["a", "b", "c"])
    }

    func testParseTableRowHandlesEmptyInput() {
        XCTAssertEqual(InlineBlock.parseTableRow(""), [])
        XCTAssertEqual(InlineBlock.parseTableRow("|"), [])
    }

    func testIsTableSeparatorAcceptsAlignmentVariants() {
        XCTAssertTrue(InlineBlock.isTableSeparator("|---|---|"))
        XCTAssertTrue(InlineBlock.isTableSeparator("| :--- | ---: | :---: |"))
        XCTAssertTrue(InlineBlock.isTableSeparator("---|---"))
    }

    func testIsTableSeparatorRejectsRegularRows() {
        XCTAssertFalse(InlineBlock.isTableSeparator("| Header | Other |"))
        XCTAssertFalse(InlineBlock.isTableSeparator("| --- | not-dashes |"))
        XCTAssertFalse(InlineBlock.isTableSeparator("just text"))
    }
}

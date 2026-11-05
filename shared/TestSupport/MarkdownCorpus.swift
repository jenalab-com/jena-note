/// Markdown inputs and the exact text macOS saves for them.
///
/// Both platforms test against this list: the shared library on every platform, and the
/// AppKit serializer on macOS. An entry describes current behavior, not ideal behavior.
public struct MarkdownCorpusCase {
    public let name: String
    public let input: String
    public let expected: String

    public init(_ name: String, _ input: String, _ expected: String) {
        self.name = name
        self.input = input
        self.expected = expected
    }
}

public enum MarkdownCorpus {
    private static let mixedDocument = """
    # 제목

    본문에 **볼드**와 *이탤릭*이 섞여 있고 `인라인 코드`도 있어요.[^1]

    ## 두 번째 제목

    - 목록 항목
    - **볼드 항목**
    1. 번호 항목

    > 인용문입니다

    ---

    ```
    let x = 1
    ```

    [링크](https://example.com) ![그림](a.png) <span style="color: #FF0000">빨강</span>

    마지막 문단.

    [^1]: 설명

    """

    public static let cases: [MarkdownCorpusCase] = [
        // Document edges
        .init("empty", "", ""),
        .init("only newlines", "\n\n", ""),
        .init("leading blank lines are dropped", "\n\n본문", "본문\n"),
        .init("paragraph gains a final newline", "가나다", "가나다\n"),
        .init("blank lines between paragraphs stay", "a\n\n\nb\n", "a\n\n\nb\n"),
        .init("surrounding spaces stay", "  a  \n    b", "  a  \n    b\n"),
        .init("korean and emoji", "😀 한글 **굵게** 👨‍👩‍👧", "😀 한글 **굵게** 👨‍👩‍👧\n"),

        // Headings
        .init("heading levels", "# a\n## b\n### c", "# a\n## b\n### c\n"),
        .init("four hashes are a paragraph", "#### d", "#### d\n"),
        .init("empty heading becomes blank", "# ", "\n"),
        .init("h1 drops bold marks", "# **a** b", "# a b\n"),
        .init("h2 drops bold marks", "## **a** b", "## a b\n"),
        .init("h3 keeps bold marks", "### **a** b", "### **a** b\n"),
        .init("heading keeps italic", "# *a*", "# *a*\n"),
        .init("h1 bold italic keeps italic only", "# ***a***", "# *a*\n"),
        .init("heading starting with an image becomes body", "# ![a](b.png) 제목", "![a](b.png) 제목\n"),
        .init("heading with a later image", "# 제목 ![a](b.png)", "# 제목 ![a](b.png)\n"),

        // Inline
        .init("all inline marks", "**a** *b* ***c*** __d__ _e_ `f`", "**a** *b* ***c*** **d** *e* `f`\n"),
        .init("neighboring bold merges", "**a****b**", "**ab**\n"),
        .init("unclosed bold is literal", "**a", "**a\n"),
        .init("underscores inside a word are italic", "a_b_c", "a*b*c\n"),
        .init("marks inside bold are literal", "**a *b* c**", "**a *b* c**\n"),
        .init("link", "[x](http://a.b)", "[x](http://a.b)\n"),
        .init("marks inside a link are literal", "[*x*](u)", "[*x*](u)\n"),
        .init("empty marks vanish", "a****b", "ab\n"),

        // Images
        .init("markdown image", "![alt](p.png)", "![alt](p.png)\n"),
        .init("image tag with width", "<img src=\"p.png\" width=\"100\">", "<img src=\"p.png\" width=\"100\">\n"),
        .init("image tag quotes normalize", "<img src='p.png' alt=\"a\" width='100'>", "<img src=\"p.png\" alt=\"a\" width=\"100\">\n"),
        .init("zero width is no width", "<img src=\"p.png\" width=\"0\">", "![](p.png)\n"),
        .init("image tag without src is literal", "<img width=\"1\">", "<img width=\"1\">\n"),

        // Color
        .init("color normalizes to uppercase six digits", "<span style=\"color: #f00\">a</span>", "<span style=\"color: #FF0000\">a</span>\n"),
        .init("color wraps inner marks", "<span style='color:#00ff00'>**a**</span>", "<span style=\"color: #00FF00\">**a**</span>\n"),
        .init("named color is literal", "<span style=\"color: red\">a</span>", "<span style=\"color: red\">a</span>\n"),
        .init("unclosed span is literal", "<span style=\"color: #000000\">a", "<span style=\"color: #000000\">a\n"),

        // Notes
        .init("note reference and definition", "본문[^1]\n\n[^1]: 설명 **b**", "본문[^1]\n\n[^1]: 설명 **b**\n"),
        .init("definition trims spaces", "[^n-1]:    설명", "[^n-1]: 설명\n"),
        .init("invalid note id is literal", "a[^b c]", "a[^b c]\n"),

        // Lists and quotes
        .init("unordered markers normalize", "- a\n* b\n+ c", "- a\n- b\n- c\n"),
        .init("ordered numbers stay", "3. a\n1. b", "3. a\n1. b\n"),
        .init("empty list items stay", "- \n1. ", "- \n1. \n"),
        .init("number without a space is a paragraph", "1.a", "1.a\n"),
        .init("quote", "> a **b**", "> a **b**\n"),
        .init("quote without a space is a paragraph", ">a", ">a\n"),
        .init("empty quote becomes blank", "> ", "\n"),

        // Rules
        .init("rule forms normalize", "---\n***\n___\n-----", "---\n---\n---\n---\n"),

        // Code. Several of these record known defects.
        .init("code keeps blank inner lines", "```\nlet a = 1\n\nlet b\n```\n끝", "```\nlet a = 1\n\nlet b\n```\n끝\n"),
        .init("code keeps marks literal", "```\n**a**\n```", "```\n**a**\n```\n"),
        .init("fence language is lost", "```swift\nx\n```", "```\nx\n```\n"),
        .init("unterminated fence closes", "```\na", "```\na\n```\n"),
        .init("neighboring fences merge", "```\na\n```\n```\nb\n```", "```\na\nb\n```\n"),
        .init("empty fence is lost", "```\n```", "\n"),
        .init("empty first code line loses the opening fence", "```\n\nabc\n```", "abc\n```\n"),
        .init("empty last code line loses the closing fence", "```\nabc\n\n```\n끝", "```\nabc\n\n끝\n"),

        // Tables. Several of these record known defects.
        .init("table header turns bold", "| A | B |\n|---|---|\n| 1 | 2 |", "| **A** | **B** |\n| --- | --- |\n| 1 | 2 |\n"),
        .init("saved table is stable", "| **A** | **B** |\n| --- | --- |\n| 1 | 2 |", "| **A** | **B** |\n| --- | --- |\n| 1 | 2 |\n"),
        .init("blank line after a table grows", "| A |\n|---|\n| 1 |\n\n끝", "| **A** |\n| --- |\n| 1 |\n\n\n끝\n"),
        .init("text right after a table gains a blank line", "| A |\n|---|\n| 1 |\n끝", "| **A** |\n| --- |\n| 1 |\n\n끝\n"),
        .init("italic in a cell is lost", "| *a* |\n|---|\n| *b* `c` |", "| **a** |\n| --- |\n| b `c` |\n"),
        .init("short rows are padded", "| A | B |\n|---|---|\n| 1 |", "| **A** | **B** |\n| --- | --- |\n| 1 |  |\n"),
        .init("empty first cell adds a blank line", "가\n|  | B |\n|---|---|\n| 1 | 2 |", "가\n\n|  | **B** |\n| --- | --- |\n| 1 | 2 |\n"),
        .init("all empty table becomes blank", "|  |\n|---|", "\n"),
        .init("link and code in cells", "| A |\n|---|\n| [x](u) `c` |", "| **A** |\n| --- |\n| [x](u) `c` |\n"),
        .init("pipe without a separator is a paragraph", "a | b", "a | b\n"),

        // A whole document
        .init("mixed document", mixedDocument, mixedDocument),
    ]
}

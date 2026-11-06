/// Markdown inputs and the exact text saved for them.
///
/// `macLegacy` records what the AppKit serializer still saves where it has a defect, so the
/// macOS tests keep describing it until the app switches to the shared code. Remove it then.
public struct MarkdownCorpusCase {
    public let name: String
    public let input: String
    public let expected: String
    public let macLegacy: String?

    public init(_ name: String, _ input: String, _ expected: String, macLegacy: String? = nil) {
        self.name = name
        self.input = input
        self.expected = expected
        self.macLegacy = macLegacy
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
        .init("heading starting with an image stays a heading", "# ![a](b.png) 제목", "# ![a](b.png) 제목\n", macLegacy: "![a](b.png) 제목\n"),
        .init("heading with a later image", "# 제목 ![a](b.png)", "# 제목 ![a](b.png)\n"),

        // Inline
        .init("all inline marks", "**a** *b* ***c*** __d__ _e_ `f`", "**a** *b* ***c*** **d** *e* `f`\n"),
        .init("neighboring bold merges", "**a****b**", "**ab**\n"),
        .init("unclosed bold is literal", "**a", "**a\n"),
        .init("underscores inside a word stay", "a_b_c snake__case__x", "a_b_c snake__case__x\n", macLegacy: "a*b*c snake**case**x\n"),
        .init("underscores at word edges are italic", "_a_b_ c", "*a_b* c\n", macLegacy: "*a*b_ c\n"),
        .init("marks inside bold are literal", "**a *b* c**", "**a *b* c**\n"),
        .init("link", "[x](http://a.b)", "[x](http://a.b)\n"),
        .init("marks inside a link are literal", "[*x*](u)", "[*x*](u)\n"),
        .init("empty marks stay", "a****b", "a****b\n", macLegacy: "ab\n"),

        // Images
        .init("markdown image", "![alt](p.png)", "![alt](p.png)\n"),
        .init("image tag with width", "<img src=\"p.png\" width=\"100\">", "<img src=\"p.png\" width=\"100\">\n"),
        .init("image tag stays as written", "<img src='p.png' alt=\"a\" width='100'>", "<img src='p.png' alt=\"a\" width='100'>\n",
              macLegacy: "<img src=\"p.png\" alt=\"a\" width=\"100\">\n"),
        .init("image tag keeps other attributes", "<img src=\"p.png\" height=\"9\" style=\"x\" />", "<img src=\"p.png\" height=\"9\" style=\"x\" />\n",
              macLegacy: "![](p.png)\n"),
        .init("zero width stays", "<img src=\"p.png\" width=\"0\">", "<img src=\"p.png\" width=\"0\">\n", macLegacy: "![](p.png)\n"),
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

        // Code
        .init("code keeps blank inner lines", "```\nlet a = 1\n\nlet b\n```\n끝", "```\nlet a = 1\n\nlet b\n```\n끝\n"),
        .init("code keeps marks literal", "```\n**a**\n```", "```\n**a**\n```\n"),
        .init("fence keeps its language", "```swift\nx\n```", "```swift\nx\n```\n", macLegacy: "```\nx\n```\n"),
        .init("unterminated fence closes", "```\na", "```\na\n```\n"),
        .init("final newline in an open fence is no line", "```\na\n", "```\na\n```\n", macLegacy: "```\na\n"),
        .init("neighboring fences stay apart", "```\na\n```\n```\nb\n```", "```\na\n```\n```\nb\n```\n", macLegacy: "```\na\nb\n```\n"),
        .init("empty fence stays", "```\n```", "```\n```\n", macLegacy: "\n"),
        .init("empty first code line stays", "```\n\nabc\n```", "```\n\nabc\n```\n", macLegacy: "abc\n```\n"),
        .init("empty last code line stays", "```\nabc\n\n```\n끝", "```\nabc\n\n```\n끝\n", macLegacy: "```\nabc\n\n끝\n"),
        .init("inline code on one line is no fence", "```a``` b", "`a` b\n", macLegacy: "\n"),
        .init("inline code can hold backticks", "`` a`b `` c", "`` a`b `` c\n", macLegacy: "` a`b  c\n"),
        .init("lone backticks stay", "`` a", "`` a\n", macLegacy: " a\n"),
        .init("a longer fence holds a shorter one", "````\n```\nx\n```\n````", "````\n```\nx\n```\n````\n", macLegacy: "x\n"),

        // Tables
        .init("table is kept as written", "| A | B |\n|---|---|\n| 1 | 2 |", "| A | B |\n| --- | --- |\n| 1 | 2 |\n",
              macLegacy: "| **A** | **B** |\n| --- | --- |\n| 1 | 2 |\n"),
        .init("bold marks an old save left in a header go away", "| **A** | **B** |\n| --- | --- |\n| 1 | 2 |", "| A | B |\n| --- | --- |\n| 1 | 2 |\n",
              macLegacy: "| **A** | **B** |\n| --- | --- |\n| 1 | 2 |\n"),
        .init("blank line after a table stays one line", "| A |\n|---|\n| 1 |\n\n끝", "| A |\n| --- |\n| 1 |\n\n끝\n",
              macLegacy: "| **A** |\n| --- |\n| 1 |\n\n\n끝\n"),
        .init("text right after a table stays right after", "| A |\n|---|\n| 1 |\n끝", "| A |\n| --- |\n| 1 |\n끝\n",
              macLegacy: "| **A** |\n| --- |\n| 1 |\n\n끝\n"),
        .init("formatting in a cell stays", "| *a* |\n|---|\n| *b* **c** `d` |", "| *a* |\n| --- |\n| *b* **c** `d` |\n",
              macLegacy: "| **a** |\n| --- |\n| b c `d` |\n"),
        .init("column alignment stays", "| A | B |\n|:--|--:|\n| 1 | 2 |", "| A | B |\n| :-- | --: |\n| 1 | 2 |\n",
              macLegacy: "| **A** | **B** |\n| --- | --- |\n| 1 | 2 |\n"),
        .init("an escaped pipe stays in its cell", "| a\\|b |\n|---|\n| c |", "| a\\|b |\n| --- |\n| c |\n",
              macLegacy: "| **a\\** | **b** |\n| --- | --- |\n| c |  |\n"),
        .init("a lone pipe line is text", "a|b\n|", "a|b\n|\n", macLegacy: "| **a** | **b** |\n| --- | --- |\n"),
        .init("short rows are padded", "| A | B |\n|---|---|\n| 1 |", "| A | B |\n| --- | --- |\n| 1 |  |\n",
              macLegacy: "| **A** | **B** |\n| --- | --- |\n| 1 |  |\n"),
        .init("empty first cell stays in the table", "가\n|  | B |\n|---|---|\n| 1 | 2 |", "가\n|  | B |\n| --- | --- |\n| 1 | 2 |\n",
              macLegacy: "가\n\n|  | **B** |\n| --- | --- |\n| 1 | 2 |\n"),
        .init("all empty table stays", "|  |\n|---|", "|  |\n| --- |\n", macLegacy: "\n"),
        .init("link and code in cells", "| A |\n|---|\n| [x](u) `c` |", "| A |\n| --- |\n| [x](u) `c` |\n",
              macLegacy: "| **A** |\n| --- |\n| [x](u) `c` |\n"),
        .init("pipe without a separator is a paragraph", "a | b", "a | b\n"),

        // A whole document
        .init("mixed document", mixedDocument, mixedDocument),
    ]
}

import SwiftUI
import WebKit

struct MarkdownView: View {
    let content: String
    @ObservedObject var viewModel: ChatViewModel
    var maxDisplayHeight: CGFloat? = nil
    @State private var webViewHeight: CGFloat = 50 

    var body: some View {
        let renderedHeight = min(webViewHeight, maxDisplayHeight ?? webViewHeight)
        let isTruncated = (maxDisplayHeight ?? .greatestFiniteMagnitude) < webViewHeight

        WebView(content: content, dynamicHeight: $webViewHeight, viewModel: viewModel)
            .frame(height: renderedHeight)
            .clipped()
            .overlay(alignment: .bottom) {
                if isTruncated {
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0),
                            Color.white.opacity(0.88),
                            Color.white
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 64)
                    .allowsHitTesting(false)
                }
            }
    }
}

class CustomWebView: WKWebView {
    var onCollect: (() -> Void)?
    var renderedContent: String?
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        let collectAction = UIAction(title: "转为卡片") { [weak self] _ in self?.onCollect?() }
        let customMenu = UIMenu(title: "", options: .displayInline, children: [collectAction])
        builder.insertSibling(customMenu, beforeMenu: .lookup)
    }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(collectAsCard(_:)) { return true }
        return super.canPerformAction(action, withSender: sender)
    }
    @objc func collectAsCard(_ sender: Any?) { onCollect?() }
}

private struct WebView: UIViewRepresentable {
    let content: String
    @Binding var dynamicHeight: CGFloat
    @ObservedObject var viewModel: ChatViewModel

    func makeUIView(context: Context) -> CustomWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "heightHandler")
        contentController.add(context.coordinator, name: "selectionHandler")
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.userContentController = contentController
        let webView = CustomWebView(frame: .zero, configuration: webConfiguration)
        webView.onCollect = { [weak webView] in
            guard let webView = webView else {
                print("❌ webView 已释放")
                return
            }

            webView.evaluateJavaScript("getLaTeXSelection()") { result, error in
                
                if let error = error {
                    print("❌ JS调用失败:", error.localizedDescription)
                    return
                }

                print("📌 JS返回结果:", result ?? "nil")

                if let text = result as? String {
                    print("✅ 选区内容:", text)

                    DispatchQueue.main.async {
                        self.viewModel.prepareCardForEditing(content: text)
                    }
                } else {
                    print("❌ result 不是 String")
                }
            }
        }
        webView.scrollView.isScrollEnabled = false
        webView.navigationDelegate = context.coordinator
        webView.backgroundColor = .clear
        webView.isOpaque = false
        return webView
    }

    func updateUIView(_ uiView: CustomWebView, context: Context) {
        if uiView.renderedContent == content { return }
        uiView.renderedContent = content
        let base64Content = Data(content.utf8).base64EncodedString()
        let katexDirectoryURL = Self.findKaTeXDirectory()
        let missingKatexMessage = katexDirectoryURL == nil
            ? "contentDiv.insertAdjacentHTML('beforeend', '<div style=\"color:#b45309;font-size:12px;margin-top:10px;\">公式渲染资源未找到，请确认 Resources/katex 已加入 App target。</div>');"
            : ""
        
        let html = """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <link rel="stylesheet" href="katex.min.css">
            <script defer src="katex.min.js"></script>
            <script defer src="auto-render.min.js"></script>
            <style>
                * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
                body {
                    font-family: -apple-system, system-ui, sans-serif;
                    font-size: 17px; line-height: 1.6; color: #1A1A1A;
                    margin: 0; padding: 0; background-color: transparent; width: 100%;
                    overflow-x: hidden; text-align: left;
                    -webkit-user-select: text !important; user-select: text !important;
                }
                #wrapper { padding: 5px 0 15px 0; width: 100%; position: relative; }
                h1, h2, h3, h4, h5, h6 {
                    color: #405940;
                    line-height: 1.25;
                    margin: 1em 0 0.45em;
                }
                h1 { font-size: 1.45em; }
                h2 { font-size: 1.28em; }
                h3 { font-size: 1.15em; }
                p { margin: 0.55em 0; }
                ul, ol { padding-left: 1.35em; margin: 0.55em 0; }
                li { margin: 0.25em 0; }
                blockquote {
                    margin: 0.75em 0;
                    padding: 0.15em 0 0.15em 0.9em;
                    border-left: 3px solid rgba(64, 89, 64, 0.35);
                    color: rgba(0, 0, 0, 0.68);
                }
                strong { font-weight: 700; color: #1F271F; }
                em {
                    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
                    font-size: 1em;
                    font-style: normal;
                    font-weight: inherit;
                    color: inherit;
                }
                a { color: #405940; text-decoration: underline; }
                code {
                    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
                    font-size: 1em;
                    font-style: normal;
                    background-color: rgba(40, 60, 40, 0.055);
                    border-radius: 5px;
                    padding: 0.02em 0.16em;
                }
                pre {
                    background-color: #F5F5F5;
                    padding: 12px;
                    border-radius: 8px;
                    overflow-x: auto;
                    white-space: pre;
                }
                pre code {
                    display: block;
                    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
                    font-size: 0.88em;
                    padding: 0;
                    background: transparent;
                    border-radius: 0;
                    line-height: 1.45;
                }
                .formula-wrapper {
                    position: relative;
                    margin: 1.2em 0;
                }
                .formula-card {
                    border-radius: 12px;
                    background: rgba(40, 60, 40, 0.05);
                    border: 1px solid rgba(0,0,0,0.06);
                    overflow-x: auto;
                }
                .math-display {
                    display: block;
                    min-width: max-content;
                    padding: 16px;
                    line-height: 1.55;
                    -webkit-user-select: text !important;
                    user-select: text !important;
                }
                .math-inline {
                    display: inline;
                    font-size: 1em;
                    padding: 0;
                    border-radius: 5px;
                    background: transparent;
                    -webkit-user-select: text !important;
                    user-select: text !important;
                }
                .katex {
                    font-size: 1em !important;
                    line-height: 1.25;
                }
                .katex-display {
                    margin: 0 !important;
                    padding: 14px !important;
                    overflow-x: auto;
                    overflow-y: hidden;
                }
                .formula-wrapper.is-scrollable::after {
                    content: "›";
                    position: absolute;
                    right: 0;
                    top: 0;
                    bottom: 0;
                    width: 30px;
                    background: linear-gradient(to right, rgba(255,255,255,0), rgba(255,255,255,1));
                    pointer-events: none;
                    display: flex;
                    align-items: center;
                    justify-content: flex-end;
                    padding-right: 8px;
                    color: rgba(0,0,0,0.3);
                    font-size: 20px;
                    border-radius: 0 12px 12px 0;
                }
            </style>
        </head>
        <body>
            <div id="wrapper"><div id="content"></div></div>
            <script>
                const contentDiv = document.getElementById('content');
                const wrapperDiv = document.getElementById('wrapper');

                function reportHeight() {
                    const height = Math.ceil(wrapperDiv.getBoundingClientRect().height);
                    if (window.webkit && window.webkit.messageHandlers.heightHandler) {
                        window.webkit.messageHandlers.heightHandler.postMessage(height);
                    }
                }

                function getLaTeXSelection() {
                    const sel = window.getSelection();
                    if (!sel || !sel.rangeCount) return "";

                    const range = sel.getRangeAt(0);
                    const container = document.createElement("div");
                    container.appendChild(range.cloneContents());

                    Array.from(container.querySelectorAll("[data-tex]")).forEach(node => {
                        const tex = node.getAttribute("data-tex") || node.textContent || "";
                        const isBlock = node.getAttribute("data-display") === "true";
                        node.replaceWith(document.createTextNode((isBlock ? "\\n$$" : "$") + tex + (isBlock ? "$$\\n" : "$")));
                    });

                    container.style.position = "fixed";
                    container.style.left = "-9999px";
                    container.style.width = "1000px";
                    container.style.whiteSpace = "pre-wrap";
                    document.body.appendChild(container);
                    const result = container.innerText;
                    document.body.removeChild(container);

                    return result.trim();
                }

                document.addEventListener('selectionchange', () => {
                    const text = getLaTeXSelection();
                    if (text && window.webkit && window.webkit.messageHandlers.selectionHandler) {
                        window.webkit.messageHandlers.selectionHandler.postMessage(text);
                    }
                });

                function updateScrollIndicators() {
                    document.querySelectorAll('.formula-card').forEach(card => {
                        if (card.scrollWidth > card.clientWidth) {
                            card.parentElement.classList.add('is-scrollable');
                        } else {
                            card.parentElement.classList.remove('is-scrollable');
                        }
                    });
                }

                function renderMathAndMeasure() {
                    const finish = () => {
                        updateScrollIndicators();
                        reportHeight();
                    };

                    if (window.katex) {
                        document.querySelectorAll("[data-tex]").forEach(node => {
                            try {
                                window.katex.render(node.getAttribute("data-tex") || "", node, {
                                    displayMode: node.getAttribute("data-display") === "true",
                                    throwOnError: false
                                });
                            } catch (error) {
                                console.log("KaTeX node render error:", error);
                            }
                        });
                        requestAnimationFrame(finish);
                        return;
                    }

                    if (window.renderMathInElement) {
                        try {
                            renderMathInElement(contentDiv, {
                                delimiters: [
                                    {left: "$$", right: "$$", display: true},
                                    {left: "\\\\[", right: "\\\\]", display: true},
                                    {left: "\\\\(", right: "\\\\)", display: false},
                                    {left: "$", right: "$", display: false}
                                ],
                                throwOnError: false,
                                ignoredTags: ["script", "noscript", "style", "textarea", "pre", "code"],
                                ignoredClasses: ["no-math"]
                            });
                        } catch (error) {
                            console.log("KaTeX render error:", error);
                        }
                        requestAnimationFrame(finish);
                        return;
                    }

                    contentDiv.insertAdjacentHTML('beforeend', '<div style="color:#b45309;font-size:12px;margin-top:10px;">公式渲染引擎没有加载成功。</div>');
                    finish();
                }

                function escapeHTML(value) {
                    return String(value)
                        .replace(/&/g, "&amp;")
                        .replace(/</g, "&lt;")
                        .replace(/>/g, "&gt;")
                        .replace(/"/g, "&quot;")
                        .replace(/'/g, "&#39;");
                }

                function mathHTML(tex, display) {
                    const escapedTex = escapeHTML(tex.trim());
                    if (display) {
                        return `<div class="formula-wrapper"><div class="formula-card"><span class="math-display" data-tex="${escapedTex}" data-display="true">\\\\[${escapedTex}\\\\]</span></div></div>`;
                    }
                    return `<span class="math-inline" data-tex="${escapedTex}" data-display="false">\\\\(${escapedTex}\\\\)</span>`;
                }

                function renderInline(text, renderMath = true) {
                    if (!renderMath) {
                        return escapeHTML(text)
                            .replace(/`([^`]+?)`/g, "<code>$1</code>")
                            .replace(/\\*\\*([^*]+?)\\*\\*/g, "<strong>$1</strong>")
                            .replace(/__([^_]+?)__/g, "<strong>$1</strong>")
                            .replace(/(^|[^*])\\*([^*\\n]+?)\\*(?!\\*)/g, "$1<em>$2</em>")
                            .replace(/(^|[^_])_([^_\\n]+?)_(?!_)/g, "$1<em>$2</em>")
                            .replace(/\\[([^\\]]+?)\\]\\((https?:\\/\\/[^\\s)]+)\\)/g, '<a href="$2">$1</a>');
                    }

                    const mathBlocks = [];
                    let safeText = text
                        .replace(/\\$\\$([\\s\\S]+?)\\$\\$/g, (_, tex) => {
                            mathBlocks.push(mathHTML(tex, true));
                            return `\\u0000MATH${mathBlocks.length - 1}\\u0000`;
                        })
                        .replace(/\\\\\\[([\\s\\S]+?)\\\\\\]/g, (_, tex) => {
                            mathBlocks.push(mathHTML(tex, true));
                            return `\\u0000MATH${mathBlocks.length - 1}\\u0000`;
                        })
                        .replace(/\\\\\\(([\\s\\S]+?)\\\\\\)/g, (_, tex) => {
                            mathBlocks.push(mathHTML(tex, false));
                            return `\\u0000MATH${mathBlocks.length - 1}\\u0000`;
                        })
                        .replace(/\\\\\\$([^$\\n]+?)\\\\\\$/g, (_, tex) => {
                            mathBlocks.push(mathHTML(tex, false));
                            return `\\u0000MATH${mathBlocks.length - 1}\\u0000`;
                        })
                        .replace(/\\$([^$\\n]+?)\\$/g, (_, tex) => {
                            mathBlocks.push(mathHTML(tex, false));
                            return `\\u0000MATH${mathBlocks.length - 1}\\u0000`;
                        });

                    let html = escapeHTML(safeText)
                        .replace(/`([^`]+?)`/g, "<code>$1</code>")
                        .replace(/\\*\\*([^*]+?)\\*\\*/g, "<strong>$1</strong>")
                        .replace(/__([^_]+?)__/g, "<strong>$1</strong>")
                        .replace(/(^|[^*])\\*([^*\\n]+?)\\*(?!\\*)/g, "$1<em>$2</em>")
                        .replace(/(^|[^_])_([^_\\n]+?)_(?!_)/g, "$1<em>$2</em>")
                        .replace(/\\[([^\\]]+?)\\]\\((https?:\\/\\/[^\\s)]+)\\)/g, '<a href="$2">$1</a>');

                    mathBlocks.forEach((math, index) => {
                        html = html.replace(new RegExp(`\\\\u0000MATH${index}\\\\u0000`, "g"), math);
                    });
                    return html;
                }

                function renderParagraph(lines) {
                    if (!lines.length) return "";
                    return `<p>${renderInline(lines.join("\\n")).replace(/\\n/g, "<br>")}</p>`;
                }

                function renderMarkdown(markdown) {
                    const lines = markdown.replace(/\\r\\n/g, "\\n").replace(/\\r/g, "\\n").split("\\n");
                    let html = "";
                    let paragraph = [];
                    let listType = null;
                    let inCode = false;
                    let codeLines = [];

                    function flushParagraph() {
                        html += renderParagraph(paragraph);
                        paragraph = [];
                    }

                    function closeList() {
                        if (listType) {
                            html += `</${listType}>`;
                            listType = null;
                        }
                    }

                    for (const line of lines) {
                        const trimmed = line.trim();

                        if (trimmed.startsWith("```")) {
                            if (inCode) {
                                html += `<pre><code>${escapeHTML(codeLines.join("\\n"))}</code></pre>`;
                                codeLines = [];
                                inCode = false;
                            } else {
                                flushParagraph();
                                closeList();
                                inCode = true;
                            }
                            continue;
                        }

                        if (inCode) {
                            codeLines.push(line);
                            continue;
                        }

                        if (!trimmed) {
                            flushParagraph();
                            closeList();
                            continue;
                        }

                        const heading = trimmed.match(/^(#{1,6})\\s+(.+)$/);
                        if (heading) {
                            flushParagraph();
                            closeList();
                            const level = heading[1].length;
                            html += `<h${level}>${renderInline(heading[2])}</h${level}>`;
                            continue;
                        }

                        const quote = trimmed.match(/^>\\s?(.+)$/);
                        if (quote) {
                            flushParagraph();
                            closeList();
                            html += `<blockquote>${renderInline(quote[1])}</blockquote>`;
                            continue;
                        }

                        const unordered = trimmed.match(/^[-*+]\\s+(.+)$/);
                        if (unordered) {
                            flushParagraph();
                            if (listType !== "ul") {
                                closeList();
                                html += "<ul>";
                                listType = "ul";
                            }
                            html += `<li>${renderInline(unordered[1])}</li>`;
                            continue;
                        }

                        const ordered = trimmed.match(/^\\d+[.)]\\s+(.+)$/);
                        if (ordered) {
                            flushParagraph();
                            if (listType !== "ol") {
                                closeList();
                                html += "<ol>";
                                listType = "ol";
                            }
                            html += `<li>${renderInline(ordered[1])}</li>`;
                            continue;
                        }

                        closeList();
                        paragraph.push(line);
                    }

                    if (inCode) {
                        html += `<pre><code>${escapeHTML(codeLines.join("\\n"))}</code></pre>`;
                    }
                    flushParagraph();
                    closeList();
                    return html;
                }

                try {
                    const raw = decodeURIComponent(escape(window.atob("\(base64Content)")));
                    contentDiv.innerHTML = renderMarkdown(raw);
                    new ResizeObserver(reportHeight).observe(wrapperDiv);
                    if (document.readyState === "loading") {
                        document.addEventListener("DOMContentLoaded", renderMathAndMeasure);
                    } else {
                        renderMathAndMeasure();
                    }
                    \(missingKatexMessage)
                } catch (e) { 
                    contentDiv.innerHTML = `<span style="color:red;">Error: ${e.message}</span>`; 
                    reportHeight();
                }
            </script>
        </body>
        </html>
        """
        uiView.loadHTMLString(html, baseURL: katexDirectoryURL)
    }

    private static func findKaTeXDirectory() -> URL? {
        let subdirectories: [String?] = ["Resources/katex", "katex", nil]

        for subdirectory in subdirectories {
            if let url = Bundle.main.url(forResource: "katex.min", withExtension: "js", subdirectory: subdirectory) {
                return url.deletingLastPathComponent()
            }
        }

        let fallbackDirectories = [
            "Resources/katex",
            "katex"
        ]
        for directory in fallbackDirectories {
            let url = Bundle.main.bundleURL
                .appendingPathComponent(directory)
                .appendingPathComponent("katex.min.js")
            if FileManager.default.fileExists(atPath: url.path) {
                return url.deletingLastPathComponent()
            }
        }
        return nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: WebView
        init(_ parent: WebView) { self.parent = parent }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "heightHandler", let height = message.body as? CGFloat {
                DispatchQueue.main.async {
                    if abs(self.parent.dynamicHeight - height) > 0.5 { self.parent.dynamicHeight = height }
                }
            } else if message.name == "selectionHandler", let selection = message.body as? String {
                DispatchQueue.main.async { self.parent.viewModel.lastSelectedText = selection }
            }
        }
    }
}

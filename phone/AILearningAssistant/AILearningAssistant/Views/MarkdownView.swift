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
        
        let html = """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <script>
                window.MathJax = {
                    tex: { 
                        inlineMath: [['$', '$'], ['\\\\(', '\\\\)']], 
                        displayMath: [['$$', '$$'], ['\\\\[', '\\\\]']] 
                    },
                    options: {
                        renderActions: {
                            addTex: [100, (doc) => {
                                for (const math of doc.math) {
                                    if (math.typesetRoot) {
                                        math.typesetRoot.setAttribute('data-tex', math.math);
                                        math.typesetRoot.setAttribute('display', math.display ? 'true' : 'false');
                                    }
                                }
                            }, '']
                        }
                    },

                };
            </script>
            <script src="https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-chtml.js" id="MathJax-script"></script>
            <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
            <style>
                * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
                body {
                    font-family: -apple-system, system-ui, sans-serif;
                    font-size: 17px; line-height: 1.6; color: #1A1A1A;
                    margin: 0; padding: 0; background-color: transparent; width: 100%;
                    overflow-x: hidden; text-align: left;
                    -webkit-user-select: text !important; user-select: text !important;
                }
                mjx-container { 
                    display: inline !important;
                    position: relative;
                    -webkit-user-select: all !important;
                    user-select: all !important;
                    pointer-events: auto !important;
                }
                mjx-container[display="true"] {
                    display: block !important;
                    margin: 1em 0 !important;
                }
                /* 消除内部节点的干扰，确保点击和选择都能击中容器 */
                mjx-container * {
                    -webkit-user-select: inherit !important;
                    user-select: inherit !important;
                    pointer-events: none !important;
                }
                #wrapper { padding: 5px 0 15px 0; width: 100%; position: relative; }
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
                mjx-container[display="true"] {
                    margin: 0 !important; padding: 16px !important;
                    display: block !important; max-width: 100% !important;
                }
                pre { background-color: #F5F5F5; padding: 12px; border-radius: 8px; overflow-x: auto; }
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

            // 1. 克隆选区基础内容
            container.appendChild(range.cloneContents());

            // 2. 找到真实 DOM 中选区覆盖的公式
        const allMjx = Array.from(document.querySelectorAll("mjx-container"));

        const intersectingMjx = allMjx.filter(mjx => {
            try {
                const rect = mjx.getBoundingClientRect();
                const rangeRects = Array.from(range.getClientRects());

                return rangeRects.some(r =>
                    !(r.right < rect.left ||
                      r.left > rect.right ||
                      r.bottom < rect.top ||
                      r.top > rect.bottom)
                );
            } catch {
                return false;
            }
        });

        intersectingMjx.forEach(mjx => {

            const tex = mjx.getAttribute("data-tex");
            if (!tex) return;

            const isBlock = mjx.getAttribute("display") === "true";

            const replacement = document.createTextNode(
                (isBlock ? "\\n$$" : "$") +
                tex +
                (isBlock ? "$$\\n" : "$")
            );

            // 查找 clone 结果中最接近的位置
            const walker = document.createTreeWalker(
                container,
                NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT
            );

            let inserted = false;

            while (walker.nextNode()) {

                const node = walker.currentNode;

                if (
                    node.textContent &&
                    mjx.textContent &&
                    node.textContent.includes(mjx.textContent.trim())
                ) {

                    node.parentNode.insertBefore(replacement, node);

                    inserted = true;

                    break;
                }
            }

            // 如果没找到合理位置才 fallback
            if (!inserted) {
                container.appendChild(replacement);
            }
        });

            // 4. 处理可能残留在 container 中的 MathJax 渲染碎片
            Array.from(container.querySelectorAll("*")).reverse().forEach(node => {
                const isMjx = node.tagName.toLowerCase().startsWith("mjx-") || 
                             (node.className && typeof node.className === "string" && node.className.includes("mjx-"));
                if (isMjx) {
                    if (node.parentNode) node.parentNode.removeChild(node);
                }
            });

            // 5. 转换为文本
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

                function doRender() {
                    if (window.MathJax && window.MathJax.typesetPromise) {
                        window.MathJax.typesetClear(); 
                        window.MathJax.typesetPromise([contentDiv]).then(() => {
                            document.querySelectorAll('mjx-container').forEach(mjx => {
                                // 处理块级公式的滚动和卡片包装
                                if(mjx.getAttribute('display') === 'true') {
                                    if(mjx.parentNode.className !== 'formula-card') {
                                        const outerWrapper = document.createElement('div');
                                        outerWrapper.className = 'formula-wrapper';
                                        
                                        const innerCard = document.createElement('div');
                                        innerCard.className = 'formula-card';
                                        
                                        mjx.parentNode.insertBefore(outerWrapper, mjx);
                                        outerWrapper.appendChild(innerCard);
                                        innerCard.appendChild(mjx);
                                        
                                        innerCard.addEventListener('scroll', () => {
                                            if (innerCard.scrollLeft > 5) {
                                                outerWrapper.classList.remove('is-scrollable');
                                            } else {
                                                outerWrapper.classList.add('is-scrollable');
                                            }
                                        });
                                    }
                                }
                            });
                            updateScrollIndicators();
                            reportHeight();
                        }).catch(err => {
                            console.log(err);
                            contentDiv.innerHTML += `<div style="color:red;font-size:12px;">MathJax Error: ${err.message}</div>`;
                        });
                    }
                }

                function tryRender(attempts) {
                    if (window.MathJax && window.MathJax.typesetPromise) {
                        doRender();
                    } else if (attempts > 0) {
                        setTimeout(() => tryRender(attempts - 1), 200);
                    } else {
                        contentDiv.innerHTML += `<div style="color:orange;font-size:12px;margin-top:10px;">[提示] 公式渲染引擎加载超时，请检查网络。</div>`;
                        reportHeight();
                    }
                }

                try {
                    const raw = decodeURIComponent(escape(window.atob("\(base64Content)")));
                    
                    // 1. 提取公式并替换为绝对安全的占位符 (防止 marked 干扰)
                    const mathBlocks = [];
                    let placeholderText = raw.replace(/\\$\\$([\\s\\S]+?)\\$\\$/g, (match) => {
                        mathBlocks.push(match);
                        return " TQAMATHBLOCK " + (mathBlocks.length - 1) + " ";
                    });
                    placeholderText = placeholderText.replace(/\\\\\\[([\\s\\S]+?)\\\\\\]/g, (match) => {
                        mathBlocks.push(match);
                        return " TQAMATHBLOCK " + (mathBlocks.length - 1) + " ";
                    });
                    placeholderText = placeholderText.replace(/\\\\\\(([\\s\\S]+?)\\\\\\)/g, (match) => {
                        mathBlocks.push(match);
                        return " TQAMATHBLOCK " + (mathBlocks.length - 1) + " ";
                    });
                    placeholderText = placeholderText.replace(/\\$([^$]+?)\\$/g, (match) => {
                        mathBlocks.push(match);
                        return " TQAMATHBLOCK " + (mathBlocks.length - 1) + " ";
                    });

                    // 2. 执行 Markdown 解析
                    let htmlResult = marked.parse(placeholderText);

                    // 3. 精准还原公式原文 (修复可能存在 HTML 解析安全问题)
                    mathBlocks.forEach((math, index) => {
                        let regex = new RegExp(`\\\\s*TQAMATHBLOCK\\\\s+${index}\\\\b\\\\s*`, "g");
                        htmlResult = htmlResult.replace(regex, () => math);
                    });

                    contentDiv.innerHTML = htmlResult;
                    new ResizeObserver(reportHeight).observe(wrapperDiv);
                    
                    // 4. 开始轮询渲染 (尝试 50 次，即 10 秒)
                    tryRender(50);
                } catch (e) { 
                    contentDiv.innerHTML = `<span style="color:red;">Error: ${e.message}</span>`; 
                    reportHeight();
                }
            </script>
        </body>
        </html>
        """
        uiView.loadHTMLString(html, baseURL: nil)
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

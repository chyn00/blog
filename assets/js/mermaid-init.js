import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs";

document.querySelectorAll("pre code.language-mermaid, .language-mermaid > .highlight > pre > code").forEach((code) => {
  const diagram = document.createElement("div");
  diagram.className = "mermaid diagram-wide";
  diagram.textContent = code.textContent;
  code.closest(".language-mermaid, pre").replaceWith(diagram);
});

mermaid.initialize({
  startOnLoad: false,
  theme: "base",
  securityLevel: "strict",
  themeVariables: {
    fontFamily: '-apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", sans-serif',
    primaryColor: "#eef1f5",
    primaryTextColor: "#171713",
    primaryBorderColor: "#68778a",
    lineColor: "#6f7782",
    secondaryColor: "#f4f2ee",
    tertiaryColor: "#ffffff",
    actorBkg: "#f1f3f6",
    actorBorder: "#788494",
    actorTextColor: "#20252b",
    signalColor: "#343b44",
    signalTextColor: "#20252b",
    noteBkgColor: "#f5f6f8",
    noteBorderColor: "#cbd1d9",
    noteTextColor: "#343b44"
  }
});

await mermaid.run({ querySelector: ".mermaid" });

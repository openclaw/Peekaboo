export function renderedHeadingText(html) {
  let content = html;
  if (content.startsWith('<a class="anchor" ')) {
    const anchorEnd = content.indexOf("</a>");
    if (anchorEnd >= 0) content = content.slice(anchorEnd + "</a>".length);
  }

  // This is renderer-owned HTML. Walk complete tags so removing one cannot expose another tag-like sequence.
  let text = "";
  for (let index = 0; index < content.length; ) {
    if (content[index] !== "<") {
      text += content[index];
      index += 1;
      continue;
    }

    const tagEnd = renderedTagEnd(content, index + 1);
    if (tagEnd < 0) {
      text += content.slice(index);
      break;
    }
    index = tagEnd + 1;
  }
  return text.trim();
}

function renderedTagEnd(html, start) {
  let quote = null;
  for (let index = start; index < html.length; index += 1) {
    const char = html[index];
    if (quote) {
      if (char === quote) quote = null;
      continue;
    }
    if (char === '"' || char === "'") {
      quote = char;
      continue;
    }
    if (char === ">") return index;
  }
  return -1;
}

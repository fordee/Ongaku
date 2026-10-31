# A small Markdown-to-HTML converter for the manual's Markdown: headings, paragraphs,
# nested lists, pipe tables, quotes, code, images, links, bold and italics.
import html, re

def inline(text):
    text = html.escape(text, quote=False)
    codes = []
    def keep(m):
        codes.append(m.group(1)); return f'\x00{len(codes) - 1}\x00'
    text = re.sub(r'`([^`]+)`', keep, text)
    text = re.sub(r'!\[([^\]]*)\]\(([^)]+)\)', r'<img alt="\1" src="\2">', text)
    text = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'<a href="\2">\1</a>', text)
    text = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', text)
    text = re.sub(r'(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])', r'<em>\1</em>', text)
    text = text.replace('&lt;br&gt;', '<br>')
    return re.sub('\x00(\\d+)\x00', lambda m: f'<code>{codes[int(m.group(1))]}</code>', text)

LIST = re.compile(r'^(\s*)([-*+]|\d+\.)\s+(.*)$')

def render_list(lines):
    """Lines of a (possibly nested) list, as HTML."""
    out, stack = [], []  # stack of (indent, tag)
    for raw in lines:
        m = LIST.match(raw)
        if m:
            indent, tag = len(m.group(1)), 'ol' if m.group(2)[0].isdigit() else 'ul'
            while stack and indent < stack[-1][0]:
                out.append(f'</li></{stack.pop()[1]}>')
            if stack and indent == stack[-1][0]:
                out.append('</li>')
            if not stack or indent > stack[-1][0]:
                stack.append((indent, tag)); out.append(f'<{tag}>')
            out.append('<li>' + inline(m.group(3)))
        else:
            out.append(' ' + inline(raw.strip()))
    while stack:
        out.append(f'</li></{stack.pop()[1]}>')
    return ''.join(out)

def table(lines):
    cells = lambda line: [c.strip() for c in line.strip().strip('|').split('|')]
    head, rows = cells(lines[0]), [cells(l) for l in lines[2:]]
    t = '<table><thead><tr>' + ''.join(f'<th>{inline(c)}</th>' for c in head) + '</tr></thead><tbody>'
    t += ''.join('<tr>' + ''.join(f'<td>{inline(c)}</td>' for c in r) + '</tr>' for r in rows)
    return t + '</tbody></table>'

def convert(md):
    md = re.sub(r'<!--.*?-->', '', md, flags=re.S)
    lines, out, i = md.split('\n'), [], 0
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1; continue
        if line.startswith('```'):
            j = i + 1
            while j < len(lines) and not lines[j].startswith('```'): j += 1
            out.append('<pre><code>' + html.escape('\n'.join(lines[i + 1:j])) + '</code></pre>'); i = j + 1; continue
        if m := re.match(r'^(#{1,6})\s+(.*)$', line):
            out.append(f'<h{len(m.group(1))}>{inline(m.group(2))}</h{len(m.group(1))}>'); i += 1; continue
        if re.match(r'^\s*(-{3,}|\*{3,})\s*$', line):
            out.append('<hr>'); i += 1; continue
        if line.startswith('|') and i + 1 < len(lines) and re.match(r'^\|\s*:?-{3,}', lines[i + 1]):
            j = i
            while j < len(lines) and lines[j].startswith('|'): j += 1
            out.append(table(lines[i:j])); i = j; continue
        if line.startswith('>'):
            j = i
            while j < len(lines) and lines[j].startswith('>'): j += 1
            out.append('<blockquote>' + convert('\n'.join(l[1:].lstrip() for l in lines[i:j])) + '</blockquote>'); i = j; continue
        if LIST.match(line):
            j = i + 1
            while j < len(lines) and (LIST.match(lines[j]) or (lines[j].startswith('  ') and lines[j].strip())
                or (not lines[j].strip() and j + 1 < len(lines) and (LIST.match(lines[j + 1]) or lines[j + 1].startswith('   ')))):
                j += 1
            out.append(render_list([l for l in lines[i:j] if l.strip()])); i = j; continue
        if m := re.match(r'^!\[([^\]]*)\]\(([^)]+)\)\s*$', line):
            out.append(f'<figure><img alt="{html.escape(m.group(1))}" src="{m.group(2)}"><figcaption>{inline(m.group(1))}</figcaption></figure>')
            i += 1; continue
        j = i
        while j < len(lines) and lines[j].strip() and not re.match(r'^(#{1,6}\s|\||>|```|!\[)', lines[j]) and not LIST.match(lines[j]):
            j += 1
        out.append('<p>' + inline(' '.join(l.strip() for l in lines[i:max(j, i + 1)])) + '</p>'); i = max(j, i + 1)
    return '\n'.join(out)

# Builds the whole manual (Docs/Manual) as one printable HTML page, for make-pdf.sh to
# print with Chrome: a cover, the contents, then each chapter on a new page, with links
# between chapters turned into links within the page.
#
#   python3 build.py out.html

import glob, html, os, re, sys

tools = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, tools)
from md import convert

manual = os.path.dirname(tools)


def slug(text):
    """A heading's anchor, as GitHub makes them."""
    return re.sub(r'[^\w\- ]', '', html.unescape(re.sub('<[^>]+>', '', text)).lower()).strip().replace(' ', '-')


def chapter(path):
    name = os.path.basename(path)[:-3]
    md = open(path).read()
    # Links within the chapter and to other chapters become links within the page; each
    # chapter's headings are prefixed with its name so anchors can't clash.
    md = re.sub(r'\]\(#([^)]+)\)', lambda m: f'](#@@{name}--{m.group(1)})', md)
    md = re.sub(r'\]\(([0-9A-Za-z_-]+)\.md(?:#([^)]*))?\)',
        lambda m: f'](#@@{m.group(1)}' + (f'--{m.group(2)}' if m.group(2) else '') + ')', md)
    md = md.replace('](#@@', '](#')
    md = md.replace('](images/', f'](file://{manual}/images/')
    body = convert(md)
    body = re.sub(r'<h([1-4])>(.*?)</h\1>',
        lambda m: f'<h{m.group(1)} id="{name}--{slug(m.group(2))}">{m.group(2)}</h{m.group(1)}>', body)
    return f'<section class="chapter" id="{name}">{body}</section>'


def main(out):
    chapters = sorted(p for p in glob.glob(manual + '/*.md') if not p.endswith('README.md'))
    # The README, without its title, is the contents page.
    contents = convert(open(manual + '/README.md').read().split('\n', 1)[1])
    contents = re.sub(r'href="([0-9A-Za-z_-]+)\.md"', r'href="#\1"', contents)
    style = open(tools + '/print.css').read()
    cover = ('<section class="cover"><div class="brand">ongaku</div><h1>Ongaku Studio</h1>'
        '<p class="subtitle">User Manual</p></section>')
    page = (f'<!doctype html><html><head><meta charset="utf-8"><title>Ongaku Studio User Manual</title>'
        f'<style>{style}</style></head><body>{cover}<section class="contents">{contents}</section>'
        f'{"".join(chapter(c) for c in chapters)}</body></html>')
    open(out, 'w').write(page)
    print(f'{len(chapters)} chapters, {page.count("<img")} images, {page.count("<table>")} tables')


if __name__ == '__main__':
    main(sys.argv[1])

"""Turn a horizontal still (TMDB backdrop, official key art) into a Coco cover.

Usage:
  python -I Make-CocoCover.py <source.jpg> <assets/experiences/<id>.jpg> [--top 0.5] [--brightness 1.0]

The cover is 2:1 (2400x1200). The app shows it as 21:10 and 16:7.4 in the
film grid, 16:9 in the game grid and 2:1 behind the details panel, always
centered with object-fit: cover. A 2:1 source keeps the subject in all of them.
--top picks which band of a taller source is kept: 0 = top, 0.5 = middle, 1 = bottom.
It also writes <out>.preview.png with the 21:10 and 16:9 crops so you can check
that no head, face or title is cut before you commit. Delete the preview after.
"""
import argparse
from PIL import Image, ImageEnhance


def crop_to(im, ratio):
    w, h = im.size
    if w / h > ratio:
        cw = int(h * ratio)
        x = (w - cw) // 2
        return im.crop((x, 0, x + cw, h))
    ch = int(w / ratio)
    y = (h - ch) // 2
    return im.crop((0, y, w, y + ch))


def main():
    p = argparse.ArgumentParser()
    p.add_argument('source')
    p.add_argument('out')
    p.add_argument('--top', type=float, default=0.5)
    p.add_argument('--brightness', type=float, default=1.0)
    a = p.parse_args()
    im = Image.open(a.source).convert('RGB')
    w, h = im.size
    if w / h < 1.7:
        raise SystemExit(f'{w}x{h} is not a horizontal still; use a backdrop, not a poster')
    if w < 1600:
        raise SystemExit(f'{w}px wide is too small; download the original size')
    if w / h > 2:
        cw = 2 * h
        im = im.crop(((w - cw) // 2, 0, (w - cw) // 2 + cw, h))
    else:
        ch = w // 2
        y = int((h - ch) * min(max(a.top, 0.0), 1.0))
        im = im.crop((0, y, w, y + ch))
    im = im.resize((2400, 1200), Image.LANCZOS)
    if a.brightness != 1.0:
        im = ImageEnhance.Brightness(im).enhance(a.brightness)
    im.save(a.out, quality=90, optimize=True, progressive=True)
    wide, card = crop_to(im, 21 / 10).resize((630, 300)), crop_to(im, 16 / 9).resize((533, 300))
    sheet = Image.new('RGB', (630 + 10 + 533, 300), 'black')
    sheet.paste(wide, (0, 0))
    sheet.paste(card, (640, 0))
    sheet.save(a.out + '.preview.png')
    print(f'{a.out}: 2400x1200; check {a.out}.preview.png')


if __name__ == '__main__':
    main()

"""Genera los íconos de FOXmin en ../Resources: python3 generar_logo.py (necesita cairosvg y Pillow).

El logo es una ventana ámbar con los tres botones de macOS, y la punta de una flecha de cursor
que tapa (borra) su esquina inferior derecha.
"""
import io
from pathlib import Path

import cairosvg
from PIL import Image, ImageChops, ImageFilter

AMBER = "#e6a84a"
OUT = Path(__file__).resolve().parent.parent / "Resources"

WINDOW = '<rect x="282" y="337" width="460" height="350" rx="62"/>'
DOTS = "".join(f'<circle cx="{x}" cy="405" r="17"/>' for x in (352, 405, 458))
ARROW_HEAD = ('<path transform="translate(560 455) scale(1.05)" d="M0 0 L0 300 L94 226 L212 214 Z" '
              'stroke="black" stroke-width="10" stroke-linejoin="round"/>')


def render(body, size=1024):
    svg = f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">{body}</svg>'
    png = cairosvg.svg2png(bytestring=svg.encode(), output_width=size, output_height=size)
    return Image.open(io.BytesIO(png)).convert("RGBA")


def alpha(body, size=1024):
    return render(body, size).getchannel("A")


def glyph_alpha(size=1024):
    """La silueta: la ventana menos los botones y menos la punta de la flecha."""
    return ImageChops.subtract(ImageChops.subtract(alpha(WINDOW, size), alpha(DOTS, size)), alpha(ARROW_HEAD, size))


def app_icon():
    tile = render('''<defs><linearGradient id="d" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#2d2d31"/><stop offset="1" stop-color="#1d1d20"/></linearGradient>
      <filter id="s" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur in="SourceAlpha" stdDeviation="10"/>
      <feOffset dy="12"/><feComponentTransfer><feFuncA type="linear" slope="0.35"/></feComponentTransfer>
      <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter></defs>
      <rect x="100" y="100" width="824" height="824" rx="185" fill="url(#d)" stroke="#3a3a3f" stroke-width="2" filter="url(#s)"/>''')
    tile.paste(Image.new("RGBA", tile.size, AMBER), (0, 0), glyph_alpha())
    tile.save(OUT / "AppIcon.png")


def menu_bar_icons():
    """Íconos "template" para la barra de menú: negro sobre transparente, macOS les pone el color.
    MenuBarIcon = encendido (silueta llena), MenuBarIconOff = apagado (solo el contorno)."""
    box = (550, 660, 1500, 1390)  # recorte ajustado a la ventana

    def square(mask):
        mask = mask.crop(box)
        side = max(mask.size)
        out = Image.new("L", (side, side), 0)
        out.paste(mask, ((side - mask.width) // 2, (side - mask.height) // 2))
        return out.resize((512, 512), Image.LANCZOS)

    filled = square(glyph_alpha(2048))
    # Contorno de la ventana recortada (unos 2 px a 36 px de alto), con los tres botones llenos
    shape = square(ImageChops.subtract(alpha(WINDOW, 2048), alpha(ARROW_HEAD, 2048)))
    outline = ImageChops.lighter(ImageChops.subtract(shape, shape.filter(ImageFilter.MinFilter(25))),
                                 square(alpha(DOTS, 2048)))

    for mask, base in [(filled, "MenuBarIcon"), (outline, "MenuBarIconOff")]:
        for size, suffix in [(18, ""), (36, "@2x")]:
            img = Image.new("RGBA", mask.size, (0, 0, 0, 0))
            img.putalpha(mask)
            img.resize((size, size), Image.LANCZOS).save(OUT / f"{base}{suffix}.png")


if __name__ == "__main__":
    app_icon()
    menu_bar_icons()
    print("Íconos generados en", OUT)

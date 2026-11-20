# Genera lanzador/PCCare.ico (diseno propio: anillo verde con visto sobre fondo azul). Uso: python lanzador/icono/generar.py
from PIL import Image, ImageDraw
import os
S = 1024
img = Image.new('RGBA', (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
d.rounded_rectangle((40, 40, S - 40, S - 40), radius=210, fill=(15, 42, 67, 255))
d.ellipse((190, 190, S - 190, S - 190), outline=(31, 179, 126, 255), width=86)
d.line([(345, 530), (470, 655), (700, 380)], fill=(255, 255, 255, 255), width=96, joint='curve')
for p in [(345, 530), (470, 655), (700, 380)]:
    d.ellipse((p[0] - 48, p[1] - 48, p[0] + 48, p[1] + 48), fill=(255, 255, 255, 255))
salida = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'PCCare.ico')
img.save(salida, format='ICO', sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
print('Icono escrito en', os.path.normpath(salida))
